/// Local notifications (B10 / Plan D D5): fire on `permission_request`
/// (channel [AlertChannel.waiting]) and `streaming_ended`
/// ([AlertChannel.finished]) while the app is backgrounded. Payload is
/// `"<machineHost>|<workspaceId>|<convId>"` so a tap can switch instance
/// and tab. This intentionally does NOT fight Android doze — the socket
/// dying in deep sleep is expected, and always-on alerting is server-side
/// ntfy (Plan A, A8).
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../protocol/protocol.dart';

/// The two Android notification channels agent alerts post to. Android sets
/// sound, vibration and importance per channel, so splitting them lets the
/// user give "agent needs you" and "turn finished" different sounds in the
/// system settings. The native relay service (`RelayAlertService.kt`) uses the
/// same ids and names — keep them in step.
enum AlertChannel {
  /// Permission prompts and questions: the turn is blocked on the user.
  waiting(
    'gaviero_agent_waiting',
    'Agent needs you',
    'The agent is waiting for a permission or an answer',
  ),

  /// A turn ended (its changes may be waiting for turn review).
  finished(
    'gaviero_turn_finished',
    'Turn finished',
    'An agent turn ended; its changes may need review',
  );

  const AlertChannel(this.id, this.name, this.description);
  final String id;
  final String name;
  final String description;

  /// Channel ids used before the split; removed so they stop showing up in
  /// the system notification settings.
  static const legacyIds = ['gaviero_agent', 'gaviero_relay_alerts'];

  NotificationDetails get details => NotificationDetails(
        android: AndroidNotificationDetails(
          id,
          name,
          channelDescription: description,
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
}

final class NotificationContext {
  String? machineHost;
  String? workspaceId;
  String? workspaceName;
  String Function(String convId)? conversationTitle;

  /// The current machine is paired through gaviero-relay, whose foreground
  /// service already alerts for finished/waiting turns — don't double up.
  bool relayCovered = false;
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
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      // Create both channels up front so each shows in the system settings
      // (where its sound is chosen) before the first alert of that kind.
      // Re-creating an existing channel keeps the user's sound choice.
      for (final channel in AlertChannel.values) {
        await android.createNotificationChannel(
          AndroidNotificationChannel(
            channel.id,
            channel.name,
            description: channel.description,
            importance: Importance.high,
          ),
        );
      }
      for (final legacy in AlertChannel.legacyIds) {
        await android.deleteNotificationChannel(channelId: legacy);
      }
      await android.requestNotificationsPermission();
    }
  }

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

  Future<void> _show(
    AlertChannel channel,
    int id,
    String title,
    String body,
    String payload,
  ) async {
    if (!_initialized || appIsForeground || context.relayCovered) return;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: channel.details,
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
        AlertChannel.waiting,
        request.requestId.hashCode,
        permissionTitle(context.workspaceName),
        permissionBody(
          conversationTitle: _titleFor(request.convId),
          request: request,
        ),
        _payloadFor(request.convId),
      );

  Future<void> onStreamingEnded(StreamingEnded ended) => _show(
        AlertChannel.finished,
        ended.turnId.hashCode,
        streamingTitle(context.workspaceName, ended),
        streamingBody(
          conversationTitle: _titleFor(ended.convId),
          ended: ended,
        ),
        _payloadFor(ended.convId),
      );
}
