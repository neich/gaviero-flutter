/// D3: InstancePickerScreen widget tests.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/directory_client.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/kv.dart';
import 'package:gaviero_remote/src/state/controller.dart';
import 'package:gaviero_remote/src/transport/connection.dart';
import 'package:gaviero_remote/src/ui/instance_picker_screen.dart';

RemoteController _controllerWith(StoreDocument doc) {
  final store = InstanceStore(kv: MemoryKv())..doc = doc;
  return RemoteController(
    instanceStore: store,
    directoryClient: DirectoryClient(
      fetch: (url, token) async => const DirectoryFetchResult(404, ''),
    ),
    connection: RemoteConnection(
      connector: (url, token) async {
        throw StateError('offline');
      },
    ),
  );
}

StoreDocument get _twoMachinesThreeInstances => StoreDocument(
  machines: const [
    MachineRecord(host: 'alpha', token: 't1', pairedAt: 'x'),
    MachineRecord(host: 'beta', token: 't2', pairedAt: 'x', needsPairing: true),
  ],
  instances: const [
    InstanceRecord(
      machineHost: 'alpha',
      workspaceId: 'w1',
      displayName: 'gaviero',
      url: 'wss://alpha:1/v1/ws',
      lastOnline: true,
    ),
    InstanceRecord(
      machineHost: 'alpha',
      workspaceId: 'w2',
      displayName: 'notes',
      url: 'wss://alpha:2/v1/ws',
      lastOnline: true,
      inUse: true,
    ),
    InstanceRecord(
      machineHost: 'beta',
      workspaceId: 'w3',
      displayName: 'flutter',
      url: 'wss://beta:3/v1/ws',
    ),
  ],
);

void main() {
  testWidgets(
    'two machines and three instances render in two sections with chips',
    (tester) async {
      final controller = _controllerWith(_twoMachinesThreeInstances);
      await tester.pumpWidget(
        MaterialApp(home: InstancePickerScreen(controller: controller)),
      );
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('gaviero'), findsOneWidget);
      expect(find.text('notes'), findsOneWidget);
      expect(find.text('flutter'), findsOneWidget);
      expect(find.text('online'), findsOneWidget);
      expect(find.text('in use'), findsOneWidget);
      expect(find.text('needs pairing'), findsOneWidget);
      expect(
        find.text('another device is connected — connecting will replace it'),
        findsOneWidget,
      );
    },
  );

  testWidgets('tapping a row calls connect with that record', (tester) async {
    final controller = _controllerWith(_twoMachinesThreeInstances);
    await tester.pumpWidget(
      MaterialApp(home: InstancePickerScreen(controller: controller)),
    );
    await tester.tap(find.text('notes'));
    await tester.pump();
    expect(controller.current?.workspaceId, 'w2');
    expect(controller.current?.displayName, 'notes');
    await controller.connection.stop();
  });

  testWidgets('forgetting an instance removes only that row', (tester) async {
    final controller = _controllerWith(_twoMachinesThreeInstances);
    await tester.pumpWidget(
      MaterialApp(home: InstancePickerScreen(controller: controller)),
    );
    await tester.longPress(find.text('notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpAndSettle();
    expect(find.text('notes'), findsNothing);
    expect(find.text('gaviero'), findsOneWidget);
    expect(find.text('flutter'), findsOneWidget);
  });
}
