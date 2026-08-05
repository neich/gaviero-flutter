import 'package:flutter/material.dart';

import 'src/state/controller.dart';
import 'src/transport/connection.dart';
import 'src/ui/chat_screen.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = RemoteController();
    _controller.initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
          final needsPairing = !_controller.isPaired ||
              _controller.connection.phase == ConnectionPhase.unauthorized;
          return needsPairing
              ? PairingScreen(controller: _controller)
              : ChatScreen(controller: _controller);
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }
}
