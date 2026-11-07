import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';

import 'src/services/deep_link.dart';
import 'src/services/notifications.dart';
import 'src/state/hub.dart';
import 'src/ui/app_shell.dart';
import 'src/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GavieroRemoteApp());
}

class GavieroRemoteApp extends StatefulWidget {
  const GavieroRemoteApp({super.key});

  @override
  State<GavieroRemoteApp> createState() => _GavieroRemoteAppState();
}

class _GavieroRemoteAppState extends State<GavieroRemoteApp>
    with WidgetsBindingObserver {
  late final RemoteHub _hub;
  final _notifications = NotificationService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hub = RemoteHub()
      ..onPermissionRequested = _notifications.onPermissionRequested
      ..onStreamingEnded = _notifications.onStreamingEnded;
    _hub.addListener(_syncNotificationContext);
    _notifications.onTap = _onNotificationTap;
    _notifications.initialize();
    _hub.initialize();
    _listenDeepLinks();
  }

  void _listenDeepLinks() {
    // uriLinkStream includes the cold-start URI (app_links singleton).
    AppLinks().uriLinkStream.listen(_onDeepLink);
  }

  Future<void> _onDeepLink(Uri uri) async {
    final target = parseGavieroRemoteOpen(uri);
    if (target == null) return;
    await _hub.openNotificationTarget(
      machineHost: target.host,
      workspaceId: target.workspaceId,
      convId: target.convId,
    );
  }

  void _syncNotificationContext() {
    final current = _hub.current;
    _notifications.context.machineHost = current?.machineHost;
    _notifications.context.workspaceId = current?.workspaceId;
    _notifications.context.workspaceName = current?.displayName;
    // Every machine is paired through gaviero-relay, whose alert service
    // already covers finished/waiting turns.
    _notifications.context.relayCovered = current != null;
    final state = _hub.session?.state;
    _notifications.context.conversationTitle = (convId) =>
        state?.conversation(convId)?.summary.title ?? convId;
  }

  Future<void> _onNotificationTap(String payload) async {
    final decoded = NotificationService.decodePayload(payload);
    if (decoded == null) return;
    final (host, workspaceId, convId) = decoded;
    await _hub.openNotificationTarget(
      machineHost: host,
      workspaceId: workspaceId,
      convId: convId,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _notifications.appIsForeground = state == AppLifecycleState.resumed;
    // Backgrounding kills the socket after the server's 60 s idle cull —
    // routine, not an error. Reconnect silently on resume (§3.7).
    if (state == AppLifecycleState.resumed) {
      _hub.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gaviero Remote',
      theme: buildTheme(),
      home: RemoteShell(hub: _hub),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hub.removeListener(_syncNotificationContext);
    _hub.dispose();
    super.dispose();
  }
}
