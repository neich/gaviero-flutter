import 'package:flutter/material.dart';

import 'src/services/notifications.dart';
import 'src/state/controller.dart';
import 'src/transport/connection.dart';
import 'src/ui/chat_screen.dart';
import 'src/ui/instance_picker_screen.dart';
import 'src/ui/pairing_screen.dart';
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
  late final RemoteController _controller;
  final _notifications = NotificationService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = RemoteController();
    _controller.state.onPermissionRequested =
        _notifications.onPermissionRequested;
    _controller.state.onStreamingEnded = _notifications.onStreamingEnded;
    _controller.addListener(_syncNotificationContext);
    _notifications.onTap = _onNotificationTap;
    _notifications.initialize();
    _controller.initialize();
  }

  void _syncNotificationContext() {
    final current = _controller.current;
    _notifications.context.machineHost = current?.machineHost;
    _notifications.context.workspaceId = current?.workspaceId;
    _notifications.context.workspaceName = current?.displayName;
    _notifications.context.conversationTitle = (convId) =>
        _controller.state.conversation(convId)?.summary.title ?? convId;
  }

  Future<void> _onNotificationTap(String payload) async {
    final decoded = NotificationService.decodePayload(payload);
    if (decoded == null) return;
    final (host, workspaceId, convId) = decoded;
    await _controller.openNotificationTarget(
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
      _controller.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gaviero Remote',
      theme: buildTheme(),
      home: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final needsHost = _controller.needsPairingHost;
          if (needsHost != null ||
              _controller.connection.phase == ConnectionPhase.unauthorized) {
            return PairingScreen(
              controller: _controller,
              forMachine: needsHost ?? _controller.current?.machineHost,
            );
          }
          if (_controller.current != null) {
            return ChatScreen(controller: _controller);
          }
          return InstancePickerScreen(controller: _controller);
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_syncNotificationContext);
    _controller.dispose();
    super.dispose();
  }
}
