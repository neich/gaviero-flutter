/// Local notifications (B10 / Plan D D5): fire on `permission_request` and
/// `streaming_ended` while the app is backgrounded. Payload is
/// `"<machineHost>|<workspaceId>|<convId>"` so a tap can switch instance
/// and tab. This intentionally does NOT fight Android doze — the socket
/// dying in deep sleep is expected, and always-on alerting is server-side
/// ntfy (Plan A, A8).
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../protocol/protocol.dart';

final class NotificationContext {
  String? machineHost;
  String? workspaceId;
  String? workspaceName;
  String Function(String convId)? conversationTitle;
}

final class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;
  NotificationContext context = NotificationContext();
  void Function(String payload)? onTap;

  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// Set by the app shell's lifecycle observer; notifications only fire
  /// while the UI is not visible.
  bool appIsForeground = true;

  Future<void> initialize() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    _initialized = await _plugin.initialize(
          settings: settings,
          onDidReceiveNotificationResponse: (response) {
            final payload = response.payload;
            if (payload == null || payload.isEmpty) return;
            onTap?.call(payload);
          },
        ) ??
        false;
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

  static String encodePayload(
          String machineHost, String? workspaceId, String convId) =>
      '$machineHost|${workspaceId ?? ''}|$convId';

  /// Returns `(machineHost, workspaceId, convId)`.
  static (String, String, String)? decodePayload(String payload) {
    final first = payload.indexOf('|');
    if (first < 0) return null;
    final second = payload.indexOf('|', first + 1);
    if (second < 0) return null;
    return (
      payload.substring(0, first),
      payload.substring(first + 1, second),
      payload.substring(second + 1),
    );
  }

  static String permissionTitle(String? workspaceName) =>
      '${workspaceName ?? 'Gaviero'} · Agent waiting for approval';

  static String permissionBody({
    required String conversationTitle,
    required PermissionRequest request,
  }) =>
      request.ask != null
          ? '$conversationTitle: the agent has a question for you'
          : '$conversationTitle · ${request.toolName}: ${request.description}';

  static String streamingTitle(String? workspaceName, StreamingEnded ended) =>
      '${workspaceName ?? 'Gaviero'} · '
      '${ended.cancelled ? 'Agent turn cancelled' : 'Agent finished'}';

  static String streamingBody({
    required String conversationTitle,
    required StreamingEnded ended,
  }) {
    if (ended.proposalCount > 0) {
      return '$conversationTitle: ${ended.proposalCount} file '
          'proposal${ended.proposalCount == 1 ? '' : 's'} to review';
    }
    if (ended.error != null) {
      return '$conversationTitle: turn ended with an error';
    }
    return '$conversationTitle: the turn is complete';
  }

  Future<void> _show(int id, String title, String body, String payload) async {
    if (!_initialized || appIsForeground) return;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: _details,
      payload: payload,
    );
  }

  String _payloadFor(String convId) => encodePayload(
        context.machineHost ?? '',
        context.workspaceId,
        convId,
      );

  String _titleFor(String convId) =>
      context.conversationTitle?.call(convId) ?? convId;

  Future<void> onPermissionRequested(PermissionRequest request) => _show(
        request.requestId.hashCode,
        permissionTitle(context.workspaceName),
        permissionBody(
          conversationTitle: _titleFor(request.convId),
          request: request,
        ),
        _payloadFor(request.convId),
      );

  Future<void> onStreamingEnded(StreamingEnded ended) => _show(
        ended.turnId.hashCode,
        streamingTitle(context.workspaceName, ended),
        streamingBody(
          conversationTitle: _titleFor(ended.convId),
          ended: ended,
        ),
        _payloadFor(ended.convId),
      );
}
