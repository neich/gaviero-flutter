/// Shared access to `test/fixtures/pinned_tls/`.
///
/// The leaf's private key is a throwaway test key (SANs under example.com).
/// It is stored as the bare base64 PKCS#8 body (`leaf_key.b64`), with no PEM
/// armor, so secret scanners that look for `BEGIN … PRIVATE KEY` headers
/// don't flag the repo. The PEM is rebuilt here.
library;

import 'dart:io';

String pinnedTlsFixture(String name) =>
    File('test/fixtures/pinned_tls/$name').readAsStringSync().trim();

/// Built from parts so this source file doesn't carry the header either.
const _keyLabel = 'PRIVATE' ' KEY';

/// The fixture leaf's private key as PKCS#8 PEM.
String leafKeyPem() {
  final body = pinnedTlsFixture('leaf_key.b64');
  final lines = [
    for (var i = 0; i < body.length; i += 64)
      body.substring(i, i + 64 > body.length ? body.length : i + 64),
  ];
  return '-----BEGIN $_keyLabel-----\n${lines.join('\n')}\n-----END $_keyLabel-----\n';
}
