/// Local notifications (B10): fire on `permission_request` and
/// `streaming_ended` while the app is backgrounded. This intentionally does
/// NOT fight Android doze with foreground services or wakelocks — the
/// socket dying in deep sleep is expected, and always-on alerting is
/// server-side ntfy (Plan A, A8).
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../protocol/protocol.dart';

final class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Set by the app shell's lifecycle observer; notifications only fire
  /// while the UI is not visible.
  bool appIsForeground = true;

  Future<void> initialize() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    _initialized = await _plugin.initialize(settings: settings) ?? false;
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'gaviero_agent',
      'Agent activity',
      channelDescription:
          'The agent is waiting for input or finished a turn',
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  Future<void> _show(int id, String title, String body) async {
    if (!_initialized || appIsForeground) return;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: _details,
    );
  }

  Future<void> onPermissionRequested(PermissionRequest request) => _show(
        request.requestId.hashCode,
        'Agent waiting for approval',
        request.ask != null
            ? 'The agent has a question for you'
            : '${request.toolName}: ${request.description}',
      );

  Future<void> onStreamingEnded(StreamingEnded ended) => _show(
        ended.turnId.hashCode,
        ended.cancelled ? 'Agent turn cancelled' : 'Agent finished',
        ended.proposalCount > 0
            ? '${ended.proposalCount} file '
                'proposal${ended.proposalCount == 1 ? '' : 's'} to review'
            : (ended.error != null
                ? 'Turn ended with an error'
                : 'The turn is complete'),
      );
}
