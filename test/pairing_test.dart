/// B9 verification (machine-verifiable part): QR payload validation —
/// `kind` and `protocol_major` are checked before storing, a wrong-major
/// QR is rejected with a clear message rather than a failed connection, and
/// a QR without gaviero-relay is refused.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/secure_store.dart';

import 'support/pinned_tls_fixtures.dart';

const _route = '0b7d245998c0e8c3-desk.gaviero.example.com';

void main() {
  final ca = pinnedTlsFixture('ca.b64');

  String qr([Map<String, Object?> extra = const {}]) => jsonEncode({
        'kind': 'gaviero-remote',
        'url': 'wss://$_route/v1/ws',
        'token': 'SECRET',
        'workspace': 'gaviero',
        'protocol_major': 1,
        'workspace_id': '0b7d245998c0e8c3',
        'machine': 'desk.gaviero.example.com',
        'directory_url': 'https://$_route/v1/instances',
        'tls_ca': ca,
        'relay_host': 'gaviero.example.com',
        'relay_secret': 'relay-secret',
        ...extra,
      });

  test('a valid QR payload parses', () {
    final config = parsePairingPayload(qr(), expectedMajor: 1);
    expect(config.url, 'wss://$_route/v1/ws');
    expect(config.token, 'SECRET');
    expect(config.workspace, 'gaviero');
    expect(config.tlsCa, ca);
    expect(config.relayHost, 'gaviero.example.com');
    expect(config.relaySecret, 'relay-secret');
  });

  test('a QR payload carries workspace_id, machine, directory_url', () {
    final config = parsePairingPayload(qr(), expectedMajor: 1);
    expect(config.workspaceId, '0b7d245998c0e8c3');
    expect(config.machine, 'desk.gaviero.example.com');
    expect(config.directoryUrl, 'https://$_route/v1/instances');
    expect(config.machineHost, 'desk.gaviero.example.com');
  });

  test('a non-https directory_url is dropped, not fatal', () {
    final config = parsePairingPayload(
        qr({'directory_url': 'http://$_route/v1/instances'}),
        expectedMajor: 1);
    expect(config.directoryUrl, isNull);
    expect(config.machine, 'desk.gaviero.example.com');
  });

  test('a QR without gaviero-relay is refused with what to set', () {
    final noRelay = Map<String, Object?>.from(jsonDecode(qr()) as Map)
      ..remove('tls_ca')
      ..remove('relay_host')
      ..remove('relay_secret');
    expect(
      () => parsePairingPayload(jsonEncode(noRelay), expectedMajor: 1),
      throwsA(isA<PairingError>().having(
          (e) => e.message, 'message', contains('remote.relay.host'))),
    );
  });

  test('a wrong kind is rejected', () {
    expect(
      () => parsePairingPayload(qr({'kind': 'other-app'}), expectedMajor: 1),
      throwsA(isA<PairingError>()),
    );
  });

  test('a wrong protocol_major is rejected with a clear message', () {
    expect(
      () => parsePairingPayload(qr({'protocol_major': 2}), expectedMajor: 1),
      throwsA(isA<PairingError>().having(
          (e) => e.message, 'message', contains('protocol v2'))),
    );
  });

  test('non-JSON and non-wss URLs are rejected', () {
    expect(() => parsePairingPayload('not json', expectedMajor: 1),
        throwsA(isA<PairingError>()));
    expect(
      () => parsePairingPayload(qr({'url': 'ws://$_route/v1/ws'}),
          expectedMajor: 1),
      throwsA(isA<PairingError>()),
      reason: 'the token only ever travels over TLS',
    );
  });
}
