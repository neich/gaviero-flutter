/// Switching instances keeps each instance's session and screens; only the
/// shown one holds a socket. The picker is reachable from every section.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/directory_client.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/kv.dart';
import 'package:gaviero_remote/src/state/controller.dart';
import 'package:gaviero_remote/src/state/hub.dart';
import 'package:gaviero_remote/src/transport/connection.dart';
import 'package:gaviero_remote/src/ui/app_shell.dart';
import 'package:gaviero_remote/src/ui/home_screen.dart';
import 'package:gaviero_remote/src/ui/instance_picker_screen.dart';

import 'every_tab_test.dart' show CapturingSocket, env, snapshot;
import 'support/relay_machine.dart';

InstanceRecord _inst(String id, String name) => InstanceRecord(
  machineHost: 'alpha',
  workspaceId: id,
  displayName: name,
  url: 'wss://$id-alpha/v1/ws',
  lastOnline: true,
);

/// A hub over [instances] on one paired machine; every dial gets a fresh
/// [CapturingSocket], recorded per url host.
(RemoteHub, Map<String, List<CapturingSocket>>) _hub(
  List<InstanceRecord> instances,
) {
  final store = InstanceStore(kv: MemoryKv())
    ..doc = StoreDocument(
      machines: const [
        MachineRecord(
          host: 'alpha',
          token: 't',
          pairedAt: 'x',
          tlsCa: testTlsCa,
          relayHost: testRelayHost,
          relaySecret: testRelaySecret,
        ),
      ],
      instances: instances,
    );
  final dials = <String, List<CapturingSocket>>{};
  final hub = RemoteHub(
    instanceStore: store,
    directoryClient: DirectoryClient(
      fetch: (url, token) async => const DirectoryFetchResult(404, ''),
    ),
    connectionFactory: () => RemoteConnection(
      connector: (url, token) async {
        final socket = CapturingSocket();
        (dials[url.host] ??= []).add(socket);
        return socket;
      },
    ),
  );
  return (hub, dials);
}

Future<void> _stopAll(RemoteHub hub) async {
  for (final s in hub.sessions) {
    await s.connection.stop();
  }
}

void main() {
  final a = _inst('wa', 'gaviero');
  final b = _inst('wb', 'notes');

  test('switching away closes the socket but keeps the session state', () async {
    final (hub, dials) = _hub([a, b]);
    await hub.connect(a);
    final sessionA = hub.session!;
    sessionA.state.applyEnvelope(env(snapshot()));
    sessionA.state.view('c2');

    await hub.connect(b);
    expect(hub.session, isNot(same(sessionA)));
    expect(hub.sessions, hasLength(2));
    expect(sessionA.connection.phase, ConnectionPhase.disconnected);
    expect(sessionA.state.conversations, hasLength(2));

    await hub.connect(a);
    expect(hub.session, same(sessionA));
    expect(sessionA.state.viewedId, 'c2');
    expect(hub.sessions.last.connection.phase, ConnectionPhase.disconnected);
    // A second dial on the same connection object.
    expect(dials['wa-alpha'], hasLength(2));
    expect(dials['wb-alpha'], hasLength(1));
    await _stopAll(hub);
  });

  test('connecting to the shown instance again does not redial', () async {
    final (hub, dials) = _hub([a]);
    await hub.connect(a);
    hub.showInstances();
    await hub.connect(a);
    expect(hub.showingInstances, isFalse);
    expect(dials['wa-alpha'], hasLength(1));
    await _stopAll(hub);
  });

  test('the least recently shown session beyond the cap is closed', () async {
    final all = [for (var i = 0; i < 6; i++) _inst('w$i', 'ws $i')];
    final (hub, _) = _hub(all);
    for (final inst in all.take(RemoteHub.maxSessions)) {
      await hub.connect(inst);
    }
    // w0 shown again: w1 is now the least recent.
    await hub.connect(all[0]);
    final w1 = hub.sessions.firstWhere((s) => s.current!.workspaceId == 'w1');
    await hub.connect(all[4]);
    expect(hub.sessions, hasLength(RemoteHub.maxSessions));
    expect(hub.sessions, isNot(contains(w1)));
    expect(
      hub.sessions.map((s) => s.current!.workspaceId),
      unorderedEquals(['w0', 'w2', 'w3', 'w4']),
    );
    await _stopAll(hub);
  });

  test('forgetting a hidden instance drops its session', () async {
    final (hub, _) = _hub([a, b]);
    await hub.connect(a);
    await hub.connect(b);
    await hub.forgetInstance(a.key);
    expect(hub.sessions.map((s) => s.current!.workspaceId), ['wb']);
    expect(hub.current?.workspaceId, 'wb');
    await _stopAll(hub);
  });

  group('RemoteShell', () {
    HomeSection shownSection(WidgetTester tester, RemoteController session) {
      final stack = tester.widget<IndexedStack>(
        find
            .descendant(
              of: find.byKey(ObjectKey(session), skipOffstage: false),
              matching: find.byType(IndexedStack, skipOffstage: false),
            )
            .first,
      );
      return HomeSection.values[stack.index!];
    }

    /// Closing a socket whose subscription is already cancelled awaits a
    /// root-zone future, which only completes on the real microtask queue:
    /// give it a turn between fake-async pumps.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> drive(WidgetTester tester, Future<void> work) async {
      var done = false;
      work.whenComplete(() => done = true);
      for (var i = 0; i < 10 && !done; i++) {
        await settle(tester);
      }
      expect(done, isTrue);
    }

    testWidgets('the picker opens from any section and a kept instance '
        'comes back on the same section', (tester) async {
      final (hub, _) = _hub([a, b]);
      await drive(tester, hub.connect(a));
      final sessionA = hub.session!;
      await tester.pumpWidget(MaterialApp(home: RemoteShell(hub: hub)));

      await tester.tap(find.byKey(const Key('section-files')));
      await tester.pump();
      expect(shownSection(tester, sessionA), HomeSection.files);

      // From Files, straight to the picker.
      await tester.tap(find.byKey(const Key('section-instances')));
      await settle(tester);
      expect(find.byType(InstancePickerScreen), findsOneWidget);
      expect(find.text('current instance'), findsOneWidget);

      await tester.tap(find.text('notes'));
      await settle(tester);
      final sessionB = hub.session!;
      expect(sessionB, isNot(same(sessionA)));
      expect(find.byType(InstancePickerScreen), findsNothing);
      expect(shownSection(tester, sessionB), HomeSection.conversations);
      // A's screen is still mounted, offstage, on Files.
      expect(shownSection(tester, sessionA), HomeSection.files);

      await tester.tap(find.byKey(const Key('section-instances')));
      await settle(tester);
      await tester.tap(find.text('gaviero'));
      await settle(tester);
      expect(hub.session, same(sessionA));
      expect(shownSection(tester, sessionA), HomeSection.files);
      expect(
        find.byKey(ObjectKey(sessionA)),
        findsOneWidget,
        reason: 'shown, not rebuilt',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await drive(tester, _stopAll(hub));
      hub.dispose();
    });

    testWidgets('Back from the picker returns to the current instance', (
      tester,
    ) async {
      final (hub, _) = _hub([a, b]);
      await drive(tester, hub.connect(a));
      final sessionA = hub.session!;
      await tester.pumpWidget(MaterialApp(home: RemoteShell(hub: hub)));
      await tester.tap(find.byKey(const Key('section-shells')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('section-instances')));
      await settle(tester);
      expect(find.byType(InstancePickerScreen), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.byType(InstancePickerScreen), findsNothing);
      expect(hub.session, same(sessionA));
      // Back went to the picker only, not to the hidden home screen.
      expect(shownSection(tester, sessionA), HomeSection.shells);

      await tester.pumpWidget(const SizedBox.shrink());
      await drive(tester, _stopAll(hub));
      hub.dispose();
    });
  });
}
