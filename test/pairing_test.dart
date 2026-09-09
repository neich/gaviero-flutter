/// B9 verification (machine-verifiable part): QR payload validation —
/// `kind` and `protocol_major` are checked before storing, a wrong-major
/// QR is rejected with a clear message rather than a failed connection.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/secure_store.dart';

const valid = '{"kind":"gaviero-remote",'
    '"url":"wss://host.tailnet.ts.net:4443/v1/ws",'
    '"token":"SECRET","workspace":"gaviero","protocol_major":1}';

const valid11 = '{"kind":"gaviero-remote",'
    '"url":"wss://host.tailnet.ts.net:4443/v1/ws",'
    '"token":"SECRET","workspace":"gaviero","protocol_major":1,'
    '"workspace_id":"0b7d245998c0e8c3","machine":"host.tailnet.ts.net",'
    '"directory_url":"https://host.tailnet.ts.net:49151/v1/instances"}';

void main() {
  test('a valid QR payload parses', () {
    final config = parsePairingPayload(valid, expectedMajor: 1);
    expect(config.url, 'wss://host.tailnet.ts.net:4443/v1/ws');
    expect(config.token, 'SECRET');
    expect(config.workspace, 'gaviero');
  });

  test('a 1.0 QR payload leaves the 1.1 keys null and derives the machine '
      'from the URL host', () {
    final config = parsePairingPayload(valid, expectedMajor: 1);
    expect(config.workspaceId, isNull);
    expect(config.machine, isNull);
    expect(config.directoryUrl, isNull);
    expect(config.machineHost, 'host.tailnet.ts.net');
  });

  test('a 1.1 QR payload carries workspace_id, machine, directory_url', () {
    final config = parsePairingPayload(valid11, expectedMajor: 1);
    expect(config.workspaceId, '0b7d245998c0e8c3');
    expect(config.machine, 'host.tailnet.ts.net');
    expect(config.directoryUrl,
        'https://host.tailnet.ts.net:49151/v1/instances');
    expect(config.machineHost, 'host.tailnet.ts.net');
  });

  test('a non-https directory_url is dropped, not fatal', () {
    final config = parsePairingPayload(
        valid11.replaceFirst('https://', 'http://'),
        expectedMajor: 1);
    expect(config.directoryUrl, isNull);
    expect(config.machine, 'host.tailnet.ts.net');
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
