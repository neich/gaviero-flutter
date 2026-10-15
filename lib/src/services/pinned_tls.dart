/// Trust and routing for machines reached through a relay.
///
/// * Pinned CA (desktop `remote.tlsMode = "pinnedCa"`): the pairing QR
///   carries the machine's private CA as `tls_ca` (base64 DER). For that
///   machine the app trusts ONLY this CA — never the system roots — and
///   host-name checking stays on.
/// * gaviero-relay (`relay_host` in the QR): every connection is dialled to
///   the relay (port 443) and TLS is started with SNI = the URL host (the
///   instance's route). The relay forwards by SNI and never decrypts, so
///   TLS is still end to end with the machine's sidecar.
///
/// Machines without `tls_ca` keep default system trust (Tailscale certs
/// chain to Let's Encrypt). dart:io only; no extra packages.
library;

import 'dart:convert';
import 'dart:io';

/// Normalizes a QR `tls_ca` value to compact base64 DER, or returns null
/// when it is not one X.509 certificate. A PEM `CERTIFICATE` block is also
/// accepted; anything carrying a private key is refused outright.
String? normalizeTlsCa(String raw) {
  if (raw.contains('PRIVATE KEY')) return null;
  var body = raw;
  const begin = '-----BEGIN CERTIFICATE-----';
  const end = '-----END CERTIFICATE-----';
  if (body.contains(begin)) {
    final start = body.indexOf(begin) + begin.length;
    final stop = body.indexOf(end, start);
    if (stop < 0) return null;
    body = body.substring(start, stop);
  }
  final compact = body.replaceAll(RegExp(r'\s'), '');
  if (compact.isEmpty || compact.contains('-')) return null;
  final List<int> der;
  try {
    der = base64.decode(compact);
  } on FormatException {
    return null;
  }
  // A DER certificate is a SEQUENCE (0x30) with a long-form length.
  if (der.length < 64 || der[0] != 0x30 || der[1] < 0x81) return null;
  return compact;
}

/// The PEM form `SecurityContext` expects, 64-column body.
String tlsCaPem(String tlsCa) {
  final lines = StringBuffer('-----BEGIN CERTIFICATE-----\n');
  for (var i = 0; i < tlsCa.length; i += 64) {
    lines.writeln(tlsCa.substring(i, i + 64 > tlsCa.length ? tlsCa.length : i + 64));
  }
  lines.writeln('-----END CERTIFICATE-----');
  return lines.toString();
}

/// A context that trusts only [tlsCa].
SecurityContext pinnedSecurityContext(String tlsCa) =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(tlsCaPem(tlsCa)));

/// `host` or `host:port`, DNS-ish characters only.
bool isValidRelayHost(String value) =>
    RegExp(r'^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$').hasMatch(value);

/// Split `host[:port]` (default port 443).
(String, int) splitRelayHost(String relayHost) {
  final i = relayHost.lastIndexOf(':');
  if (i > 0) {
    final port = int.tryParse(relayHost.substring(i + 1));
    if (port != null) return (relayHost.substring(0, i), port);
  }
  return (relayHost, 443);
}

/// `HttpClient` for a machine:
/// * relay: dial `relayHost`, TLS with SNI = the URL host, pinned CA;
/// * pinned CA only: normal dialling, pinned CA;
/// * neither: default system trust.
///
/// The URI handed to the factory may report port 0 for a port-less `wss:`
/// URL (verified 2026-10-15), so the relay address never comes from it.
HttpClient httpClientFor(String? tlsCa, {String? relayHost}) {
  if (relayHost != null && tlsCa != null) {
    final (host, port) = splitRelayHost(relayHost);
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final task = await Socket.startConnect(host, port);
      final secured = task.socket.then((socket) {
        socket.setOption(SocketOption.tcpNoDelay, true);
        return SecureSocket.secure(
          socket,
          host: uri.host,
          context: pinnedSecurityContext(tlsCa),
        );
      });
      return ConnectionTask.fromSocket(secured, task.cancel);
    };
    return client;
  }
  return tlsCa == null
      ? HttpClient()
      : HttpClient(context: pinnedSecurityContext(tlsCa));
}
