/// Bridge to the native gaviero-relay alert service (Android
/// `RelayAlertService`, a `specialUse` foreground service that replaces the
/// ntfy app). Dart only computes the config; the service runs without a
/// Flutter engine, survives the app being swiped away, and restarts on boot.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'instance_store.dart';
import 'pinned_tls.dart';

final class RelayAlerts {
  static const _defaultChannel = MethodChannel('dev.gaviero/relay_alerts');
  final MethodChannel _channel;
  final bool _enabled;

  /// [enabled] defaults to "running on Android" so desktop test runs never
  /// touch the platform channel.
  RelayAlerts({MethodChannel? channel, bool? enabled})
    : _channel = channel ?? _defaultChannel,
      _enabled = enabled ?? Platform.isAndroid;

  /// One stream per relay host (machines sharing a relay share its stream),
  /// plus display names the service uses for notification titles.
  static Map<String, Object?> configFor(StoreDocument doc) {
    final relays = <String, String>{};
    for (final m in doc.machines) {
      final host = m.relayHost, secret = m.relaySecret;
      if (m.needsPairing) continue;
      final (h, port) = splitRelayHost(host);
      relays.putIfAbsent(port == 443 ? 'https://$h' : 'https://$h:$port', () => secret);
    }
    return {
      'relays': [
        for (final e in relays.entries) {'base_url': e.key, 'secret': e.value},
      ],
      'names': {
        for (final i in doc.instances)
          if (i.workspaceId != null) '${i.machineHost}|${i.workspaceId}': i.displayName,
      },
    };
  }

  /// Push the current config; the service starts, restarts or stops itself.
  Future<void> sync(StoreDocument doc) async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod<void>('configure', jsonEncode(configFor(doc)));
    } on MissingPluginException {
      // Not on a build with the native service.
    } on PlatformException {
      // Service start refused (e.g. background start restrictions); the next
      // foreground sync retries.
    }
  }

  /// Ask once for the battery-optimisation exemption (ntfy does the same;
  /// it keeps the stream alive under OEM battery managers).
  Future<void> requestBatteryExemption() async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod<void>('requestBatteryExemption');
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }
}
