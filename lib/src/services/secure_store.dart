/// Pairing configuration — host + bearer token — kept in
/// `flutter_secure_storage`. The QR payload is the only intentional display
/// of the token; it never appears in a URL, query string, or log.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class PairingConfig {
  /// `wss://host.tailnet.ts.net:PORT/v1/ws`
  final String url;
  final String token;

  /// Workspace display name from the QR — cosmetic only.
  final String workspace;

  const PairingConfig({
    required this.url,
    required this.token,
    required this.workspace,
  });
}

/// Thrown when a scanned QR is not a valid gaviero-remote pairing payload.
final class PairingError implements Exception {
  final String message;
  const PairingError(this.message);

  @override
  String toString() => message;
}

/// Parses and validates the QR payload (PLAN.md B9):
/// `{ kind, url, token, workspace, protocol_major }`.
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
  return PairingConfig(
    url: url,
    token: token,
    workspace: (decoded['workspace'] as String?) ?? '',
  );
}

final class PairingStore {
  static const _urlKey = 'pairing_url';
  static const _tokenKey = 'pairing_token';
  static const _workspaceKey = 'pairing_workspace';

  final FlutterSecureStorage _storage;

  const PairingStore([this._storage = const FlutterSecureStorage()]);

  Future<PairingConfig?> load() async {
    final url = await _storage.read(key: _urlKey);
    final token = await _storage.read(key: _tokenKey);
    if (url == null || token == null) return null;
    return PairingConfig(
      url: url,
      token: token,
      workspace: await _storage.read(key: _workspaceKey) ?? '',
    );
  }

  Future<void> save(PairingConfig config) async {
    await _storage.write(key: _urlKey, value: config.url);
    await _storage.write(key: _tokenKey, value: config.token);
    await _storage.write(key: _workspaceKey, value: config.workspace);
  }

  /// Used on 4001 (`unauthorized`) and 4006 (`token_rotated`).
  Future<void> clear() async {
    await _storage.delete(key: _urlKey);
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _workspaceKey);
  }
}
