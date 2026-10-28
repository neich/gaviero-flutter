/// Pairing configuration parsed from the `/remote` QR. The QR payload is
/// the only intentional display of the token; it never appears in a URL,
/// query string, or log.
library;

import 'dart:convert';

import 'pinned_tls.dart';

final class PairingConfig {
  /// `wss://<route>/v1/ws`, where the route
  /// (`<workspace-id>-<machine>.<relay host>`) is sent as SNI to the relay
  /// and never looked up in DNS.
  final String url;

  /// The machine token (1.1) unless the workspace opted out of machine
  /// scope, in which case it is that workspace's own token.
  final String token;

  /// Workspace display name from the QR — cosmetic only.
  final String workspace;

  /// 1.1, optional: hex workspace identity.
  final String? workspaceId;

  /// 1.1, optional: the machine host (`<machine>.<relay host>`) the token
  /// is scoped to.
  final String? machine;

  /// 1.1, optional: `https://<route>/v1/instances`.
  final String? directoryUrl;

  /// The machine's private CA (base64 DER). Only this CA is trusted for the
  /// machine.
  final String tlsCa;

  /// Every connection to this machine is dialled to `relayHost` (port 443
  /// unless `host:port`) and names the instance by SNI.
  final String relayHost;

  /// Bearer secret for the relay's notification stream.
  final String relaySecret;

  const PairingConfig({
    required this.url,
    required this.token,
    required this.workspace,
    this.workspaceId,
    this.machine,
    this.directoryUrl,
    required this.tlsCa,
    required this.relayHost,
    required this.relaySecret,
  });

  /// The machine this pairing belongs to: the QR's `machine` when present,
  /// else the host of the instance URL.
  String get machineHost => machine ?? Uri.parse(url).host;
}

/// Thrown when a scanned QR is not a valid gaviero-remote pairing payload.
final class PairingError implements Exception {
  final String message;
  const PairingError(this.message);

  @override
  String toString() => message;
}

/// Parses and validates the QR payload (PLAN.md B9, PLAN-D.md §0.1 item 5):
/// `{ kind, url, token, workspace, protocol_major }`, the relay keys
/// `tls_ca`, `relay_host`, `relay_secret` (all required — gaviero-relay is
/// the only way to reach a machine), and the optional 1.1 keys
/// `workspace_id`, `machine`, `directory_url`. A malformed optional key is
/// ignored rather than rejected.
PairingConfig parsePairingPayload(String raw, {required int expectedMajor}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw const PairingError('This QR code is not a gaviero pairing code.');
  }
  if (decoded is! Map<String, Object?>) {
    throw const PairingError('This QR code is not a gaviero pairing code.');
  }
  if (decoded['kind'] != 'gaviero-remote') {
    throw const PairingError('This QR code is not a gaviero pairing code.');
  }
  final major = decoded['protocol_major'];
  if (major != expectedMajor) {
    throw PairingError(
        'This pairing code is for protocol v$major, but this app speaks '
        'v$expectedMajor. Update the app or the desktop so they match.');
  }
  final url = decoded['url'];
  final token = decoded['token'];
  if (url is! String || !url.startsWith('wss://') || token is! String) {
    throw const PairingError('The pairing code is malformed.');
  }
  final Map<String, Object?> payload = decoded;
  String? optional(String key) {
    final value = payload[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  final directoryUrl = optional('directory_url');
  // The relay keys are all-or-nothing: without the CA the end-to-end TLS
  // through the relay can't be verified, and without the secret the
  // notification stream can't be opened.
  final relayHost = optional('relay_host');
  final relaySecret = optional('relay_secret');
  final rawTlsCa = optional('tls_ca');
  if (relayHost == null && relaySecret == null && rawTlsCa == null) {
    throw const PairingError(
        'This pairing code has no gaviero-relay. Set remote.relay.host and '
        'remote.relay.secret on the desktop, restart gaviero, and run '
        '/remote again.');
  }
  final tlsCa = rawTlsCa == null ? null : normalizeTlsCa(rawTlsCa);
  if (rawTlsCa != null && tlsCa == null) {
    throw const PairingError(
        'The pairing code carries an invalid certificate. Run /remote again.');
  }
  if (relayHost == null ||
      !isValidRelayHost(relayHost) ||
      relaySecret == null ||
      tlsCa == null) {
    throw const PairingError(
        'The relay pairing code is incomplete. Run /remote again.');
  }
  return PairingConfig(
    url: url,
    token: token,
    workspace: (decoded['workspace'] as String?) ?? '',
    workspaceId: optional('workspace_id'),
    machine: optional('machine'),
    directoryUrl:
        directoryUrl != null && directoryUrl.startsWith('https://')
            ? directoryUrl
            : null,
    tlsCa: tlsCa,
    relayHost: relayHost,
    relaySecret: relaySecret,
  );
}
