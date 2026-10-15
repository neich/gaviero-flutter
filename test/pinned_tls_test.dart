/// VPS-relay pairing (`remote.tlsMode = "pinnedCa"` on the desktop): the QR
/// carries the machine CA as `tls_ca`; the app trusts only that CA for the
/// machine. Fixtures in `test/fixtures/pinned_tls/` were produced by the
/// desktop's own generator (`gaviero_remote::pairing::ensure_pinned_ca`),
/// with a leaf valid until 2035-12-31 and CAs until ~2036-10.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/pinned_tls.dart';
import 'package:gaviero_remote/src/services/secure_store.dart';

import 'support/pinned_tls_fixtures.dart';

String _fixture(String name) => pinnedTlsFixture(name);

String _qr({Object? tlsCa}) => jsonEncode({
      'kind': 'gaviero-remote',
      'url': 'wss://desk.example.com:50101/v1/ws',
      'token': 'tok',
      'workspace': 'gaviero',
      'protocol_major': 1,
      'machine': 'desk.example.com',
      'tls_ca': ?tlsCa,
    });

void main() {
  final ca = _fixture('ca.b64');
  final otherCa = _fixture('other_ca.b64');

  group('normalizeTlsCa', () {
    test('accepts the base64 DER the desktop emits', () {
      expect(normalizeTlsCa(ca), ca);
    });

    test('accepts a PEM CERTIFICATE block and compacts it', () {
      expect(normalizeTlsCa(tlsCaPem(ca)), ca);
    });

    test('refuses garbage and anything carrying a private key', () {
      expect(normalizeTlsCa('not base64!'), isNull);
      expect(normalizeTlsCa(base64.encode(utf8.encode('short'))), isNull);
      expect(normalizeTlsCa(leafKeyPem()), isNull);
    });
  });

  group('pairing payload', () {
    test('carries tls_ca into the pairing config', () {
      final config = parsePairingPayload(_qr(tlsCa: ca), expectedMajor: 1);
      expect(config.tlsCa, ca);
      expect(config.machineHost, 'desk.example.com');
    });

    test('a Tailscale QR has no tls_ca', () {
      expect(parsePairingPayload(_qr(), expectedMajor: 1).tlsCa, isNull);
    });

    test('a malformed tls_ca rejects the pairing instead of dropping it', () {
      expect(
        () => parsePairingPayload(_qr(tlsCa: 'garbage'), expectedMajor: 1),
        throwsA(isA<PairingError>()),
      );
    });

    test('the machine record persists the CA across a JSON round-trip', () {
      final record = MachineRecord(
        host: 'desk.example.com',
        token: 'tok',
        pairedAt: '2026-10-14T00:00:00Z',
        tlsCa: ca,
      );
      final back = MachineRecord.fromJson(
        Map<String, Object?>.from(jsonDecode(jsonEncode(record.toJson())) as Map),
      );
      expect(back.tlsCa, ca);
      expect(back.copyWith(directoryUrl: 'https://x/v1/instances').tlsCa, ca);
    });
  });

  group('TLS handshake (dart:io BoringSSL)', () {
    late SecureServerSocket server;

    setUp(() async {
      final ctx = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(_fixture('leaf_cert.pem')))
        ..usePrivateKeyBytes(utf8.encode(leafKeyPem()));
      server = await SecureServerSocket.bind('127.0.0.1', 0, ctx);
      server.listen((socket) => socket.close(), onError: (_) {});
    });

    tearDown(() => server.close());

    Future<SecureSocket> handshake(SecurityContext ctx, String host) async {
      final raw = await Socket.connect('127.0.0.1', server.port);
      return SecureSocket.secure(raw, host: host, context: ctx);
    }

    test('succeeds when the app trusts the QR CA', () async {
      final s = await handshake(pinnedSecurityContext(ca), 'desk.example.com');
      expect(s.peerCertificate?.subject, contains('desk.example.com'));
      await s.close();
    });

    test('fails with another machine\'s CA', () async {
      await expectLater(
        handshake(pinnedSecurityContext(otherCa), 'desk.example.com'),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('fails on a host-name mismatch', () async {
      await expectLater(
        handshake(pinnedSecurityContext(ca), 'vps.example.com'),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('fails with system trust when no tls_ca is stored', () async {
      await expectLater(
        handshake(SecurityContext.defaultContext, 'desk.example.com'),
        throwsA(isA<HandshakeException>()),
      );
    });

  });
}
