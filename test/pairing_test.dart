/// B9 verification (machine-verifiable part): QR payload validation —
/// `kind` and `protocol_major` are checked before storing, a wrong-major
/// QR is rejected with a clear message rather than a failed connection.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/secure_store.dart';

const valid = '{"kind":"gaviero-remote",'
    '"url":"wss://host.tailnet.ts.net:4443/v1/ws",'
    '"token":"SECRET","workspace":"gaviero","protocol_major":1}';

void main() {
  test('a valid QR payload parses', () {
    final config = parsePairingPayload(valid, expectedMajor: 1);
    expect(config.url, 'wss://host.tailnet.ts.net:4443/v1/ws');
    expect(config.token, 'SECRET');
    expect(config.workspace, 'gaviero');
  });

  test('a wrong kind is rejected', () {
    expect(
      () => parsePairingPayload(
          valid.replaceFirst('gaviero-remote', 'other-app'),
          expectedMajor: 1),
      throwsA(isA<PairingError>()),
    );
  });

  test('a wrong protocol_major is rejected with a clear message', () {
    expect(
      () => parsePairingPayload(
          valid.replaceFirst('"protocol_major":1', '"protocol_major":2'),
          expectedMajor: 1),
      throwsA(isA<PairingError>().having(
          (e) => e.message, 'message', contains('protocol v2'))),
    );
  });

  test('non-JSON and non-wss URLs are rejected', () {
    expect(() => parsePairingPayload('not json', expectedMajor: 1),
        throwsA(isA<PairingError>()));
    expect(
      () => parsePairingPayload(valid.replaceFirst('wss://', 'ws://'),
          expectedMajor: 1),
      throwsA(isA<PairingError>()),
      reason: 'the token only ever travels over TLS',
    );
  });
}
