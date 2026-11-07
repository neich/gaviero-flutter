/// Everything below `MaterialApp`: the pairing screen, the instance picker,
/// and one [HomeScreen] per session the hub keeps. Every kept home screen
/// stays mounted (offstage when not shown), so returning to an instance
/// lands on the same section, open file, shell tab, drafts and scroll
/// positions. The picker and pairing screen cover them without unmounting
/// them.
library;

import 'package:flutter/material.dart';

import '../state/hub.dart';
import '../transport/connection.dart';
import 'home_screen.dart';
import 'instance_picker_screen.dart';
import 'pairing_screen.dart';

class RemoteShell extends StatelessWidget {
  final RemoteHub hub;

  const RemoteShell({super.key, required this.hub});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final session = hub.session;
        final needsHost = hub.needsPairingHost;
        final pairing =
            needsHost != null ||
            session?.connection.phase == ConnectionPhase.unauthorized;
        final cover = pairing || hub.showingInstances;
        final sessions = hub.sessions;
        return IndexedStack(
          index: cover ? 0 : 1 + sessions.indexOf(session!),
          children: [
            if (pairing)
              PairingScreen(
                key: const ValueKey('pairing'),
                controller: hub,
                forMachine: needsHost ?? hub.current?.machineHost,
              )
            else if (hub.showingInstances)
              InstancePickerScreen(
                key: const ValueKey('instances'),
                controller: hub,
              )
            else
              const SizedBox.shrink(key: ValueKey('none')),
            for (final s in sessions)
              HomeScreen(
                key: ObjectKey(s),
                controller: s,
                active: !cover && s == session,
                onShowInstances: hub.showInstances,
              ),
          ],
        );
      },
    );
  }
}
