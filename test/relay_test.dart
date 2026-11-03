/// gaviero-relay pairing: QR fields, storage, the native-service config,
/// and the app's REAL connection path (IoWsSocket / directory fetch) dialled
/// through the relay connection factory. The relay is transparent to TLS,
/// so a local TLS server reached via `relayHost = 127.0.0.1:<port>` with
/// SNI = route exercises exactly what the phone does through the relay.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/directory_client.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/pinned_tls.dart';
import 'package:gaviero_remote/src/services/relay_alerts.dart';
import 'package:gaviero_remote/src/services/secure_store.dart';
import 'package:gaviero_remote/src/transport/socket.dart';

import 'support/pinned_tls_fixtures.dart';

String _fixture(String name) => pinnedTlsFixture(name);

/// The fixture leaf's SAN — stands in for a relay route name.
const route = 'desk.example.com';

String _qr(Map<String, Object?> extra) => jsonEncode({
      'kind': 'gaviero-remote',
      'url': 'wss://$route/v1/ws',
      'token': 'tok',
      'workspace': 'gaviero',
      'protocol_major': 1,
      'machine': 'desk.gaviero.example.com',
      'workspace_id': '0b7d245998c0e8c3',
      ...extra,
    });

void main() {
  final ca = _fixture('ca.b64');

  group('relay pairing payload', () {
    test('carries relay host and secret', () {
      final c = parsePairingPayload(
        _qr({'tls_ca': ca, 'relay_host': 'gaviero.example.com', 'relay_secret': 's3'}),
        expectedMajor: 1,
      );
      expect(c.relayHost, 'gaviero.example.com');
      expect(c.relaySecret, 's3');
      expect(c.machineHost, 'desk.gaviero.example.com');
    });

    test('an incomplete relay pairing is refused', () {
      for (final extra in [
        {'tls_ca': ca, 'relay_host': 'gaviero.example.com'}, // no secret
        {'relay_host': 'gaviero.example.com', 'relay_secret': 's3'}, // no CA
        {'tls_ca': ca, 'relay_host': 'bad host!', 'relay_secret': 's3'},
      ]) {
        expect(
          () => parsePairingPayload(_qr(extra), expectedMajor: 1),
          throwsA(isA<PairingError>()),
          reason: '$extra',
        );
      }
    });

    test('machine record round-trips the relay fields', () {
      final m = MachineRecord(
        host: 'desk.gaviero.example.com',
        token: 'tok',
        pairedAt: 't',
        tlsCa: ca,
        relayHost: 'gaviero.example.com',
        relaySecret: 's3',
      );
      final back = MachineRecord.tryFromJson(
        Map<String, Object?>.from(jsonDecode(jsonEncode(m.toJson())) as Map),
      )!;
      expect(back.relayHost, 'gaviero.example.com');
      expect(back.relaySecret, 's3');
      final updated = back.copyWith(directoryUrl: 'https://x/v1/instances');
      expect(updated.relayHost, 'gaviero.example.com');
      expect(updated.relaySecret, 's3');
    });
  });

  group('relay host parsing', () {
    test('host[:port] with a 443 default', () {
      expect(splitRelayHost('gaviero.example.com'), ('gaviero.example.com', 443));
      expect(splitRelayHost('127.0.0.1:7443'), ('127.0.0.1', 7443));
      expect(isValidRelayHost('gaviero.example.com'), isTrue);
      expect(isValidRelayHost('relay.example.com:8443'), isTrue);
      expect(isValidRelayHost('https://x'), isFalse);
      expect(isValidRelayHost(''), isFalse);
    });
  });

  group('native alert service config', () {
    test('one stream per relay host, names per instance, unpaired skipped', () {
      final doc = StoreDocument(
        machines: [
          MachineRecord(host: 'desk.r.test', token: 't', pairedAt: '', tlsCa: ca,
              relayHost: 'r.test', relaySecret: 'A'),
          MachineRecord(host: 'vps.r.test', token: 't', pairedAt: '', tlsCa: ca,
              relayHost: 'r.test', relaySecret: 'A'),
          MachineRecord(host: 'lab.other.test', token: 't', pairedAt: '', tlsCa: ca,
              relayHost: 'other.test:8443', relaySecret: 'B'),
          MachineRecord(host: 'old.r2.test', token: 't', pairedAt: '', tlsCa: ca,
              relayHost: 'r2.test', relaySecret: 'C', needsPairing: true),
        ],
        instances: const [
          InstanceRecord(machineHost: 'desk.r.test', workspaceId: 'w1',
              displayName: 'gaviero', url: 'wss://w1-desk.r.test/v1/ws'),
        ],
      );
      final cfg = RelayAlerts.configFor(doc);
      expect(cfg['relays'], [
        {'base_url': 'https://r.test', 'secret': 'A'},
        {'base_url': 'https://other.test:8443', 'secret': 'B'},
      ]);
      expect(cfg['names'], {'desk.r.test|w1': 'gaviero'});
    });

    test('off-Android sync is a no-op (no platform channel touched)', () async {
      await RelayAlerts(enabled: false).sync(const StoreDocument());
    });
  });

  group('connections through the relay factory (dart:io BoringSSL)', () {
    late HttpServer server;
    late String relayHost;
    final seenHosts = <String>[];
    final seenAuth = <String?>[];

    setUp(() async {
      final ctx = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(_fixture('leaf_cert.pem')))
        ..usePrivateKeyBytes(utf8.encode(leafKeyPem()));
      server = await HttpServer.bindSecure('127.0.0.1', 0, ctx);
      relayHost = '127.0.0.1:${server.port}';
      seenHosts.clear();
      seenAuth.clear();
      server.listen((req) async {
        seenHosts.add(req.headers.host ?? '');
        seenAuth.add(req.headers.value(HttpHeaders.authorizationHeader));
        if (req.uri.path == '/v1/ws') {
          final ws = await WebSocketTransformer.upgrade(
            req,
            protocolSelector: (p) => p.contains('gaviero.v1') ? 'gaviero.v1' : null,
          );
          ws.listen((msg) => ws.add('echo:$msg'));
        } else {
          req.response
            ..statusCode = 200
            ..write('{"instances":[]}');
          await req.response.close();
        }
      });
    });

    tearDown(() => server.close(force: true));

    test('IoWsSocket reaches the route via the relay address', () async {
      final socket = await IoWsSocket.connect(
        Uri.parse('wss://$route/v1/ws'),
        'tok',
        tlsCa: ca,
        relayHost: relayHost,
      ).timeout(const Duration(seconds: 10));
      final first = socket.frames.first.timeout(const Duration(seconds: 5));
      socket.send('hi');
      expect(await first, 'echo:hi');
      await socket.close();
      expect(seenHosts.single, route, reason: 'Host header is the route');
      expect(seenAuth.single, 'Bearer tok');
    });

    test('the directory fetch takes the same path', () async {
      final result = await dartIoDirectoryFetch(
        Uri.parse('https://$route/v1/instances'),
        'tok',
        tlsCa: ca,
        relayHost: relayHost,
      ).timeout(const Duration(seconds: 10));
      expect(result.status, 200);
    });

    test('another machine\'s CA is refused through the relay', () async {
      await expectLater(
        IoWsSocket.connect(
          Uri.parse('wss://$route/v1/ws'),
          'tok',
          tlsCa: _fixture('other_ca.b64'),
          relayHost: relayHost,
        ).timeout(const Duration(seconds: 10)),
        throwsA(anything),
      );
    });
  });
}
