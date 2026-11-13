/// D3: InstancePickerScreen widget tests.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/directory_client.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/kv.dart';
import 'package:gaviero_remote/src/state/hub.dart';
import 'package:gaviero_remote/src/transport/connection.dart';
import 'package:gaviero_remote/src/ui/instance_picker_screen.dart';

import 'support/relay_machine.dart';

RemoteHub _controllerWith(StoreDocument doc) {
  final store = InstanceStore(kv: MemoryKv())..doc = doc;
  return RemoteHub(
    instanceStore: store,
    directoryClient: DirectoryClient(
      fetch: (url, token) async => const DirectoryFetchResult(404, ''),
    ),
    connectionFactory: () => RemoteConnection(
      connector: (url, token) async {
        throw StateError('offline');
      },
    ),
  );
}

StoreDocument get _twoMachinesThreeInstances => StoreDocument(
  machines: const [
    MachineRecord(host: 'alpha', token: 't1', pairedAt: 'x', tlsCa: testTlsCa,
        relayHost: testRelayHost, relaySecret: testRelaySecret),
    MachineRecord(host: 'beta', token: 't2', pairedAt: 'x', needsPairing: true,
        tlsCa: testTlsCa, relayHost: testRelayHost, relaySecret: testRelaySecret),
  ],
  instances: const [
    InstanceRecord(
      machineHost: 'alpha',
      workspaceId: 'w1',
      displayName: 'gaviero',
      url: 'wss://w1-alpha/v1/ws',
      lastOnline: true,
    ),
    InstanceRecord(
      machineHost: 'alpha',
      workspaceId: 'w2',
      displayName: 'notes',
      url: 'wss://w2-alpha/v1/ws',
      lastOnline: true,
      inUse: true,
    ),
    InstanceRecord(
      machineHost: 'beta',
      workspaceId: 'w3',
      displayName: 'flutter',
      url: 'wss://w3-beta/v1/ws',
    ),
  ],
);

void main() {
  testWidgets(
    'two machines and three instances render in one list naming each machine',
    (tester) async {
      final controller = _controllerWith(_twoMachinesThreeInstances);
      await tester.pumpWidget(
        MaterialApp(home: InstancePickerScreen(controller: controller)),
      );
      // Each row names its machine; the Machines section lists each once.
      Finder machineOf(String id) => find.descendant(
            of: find.byKey(ValueKey('instance-machine-$id')),
            matching: find.byType(Text),
          );
      expect(tester.widget<Text>(machineOf('alpha-w1')).data, 'alpha');
      expect(tester.widget<Text>(machineOf('alpha-w2')).data, 'alpha');
      expect(tester.widget<Text>(machineOf('beta-w3')).data, 'beta');
      expect(find.byKey(const ValueKey('machine-alpha')), findsOneWidget);
      expect(find.byKey(const ValueKey('machine-beta')), findsOneWidget);
      expect(find.text('Machines'), findsOneWidget);
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
    await controller.session!.connection.stop();
  });

  testWidgets('forgetting an instance removes only that row', (tester) async {
    final controller = _controllerWith(_twoMachinesThreeInstances);
    await tester.pumpWidget(
      MaterialApp(home: InstancePickerScreen(controller: controller)),
    );
    await tester.longPress(find.text('notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('notes'), findsNothing);
    expect(find.text('gaviero'), findsOneWidget);
    expect(find.text('flutter'), findsOneWidget);
  });

  group('status order, grey offline, remove offline', () {
    testWidgets('rows are ordered in use, online, then offline', (
      tester,
    ) async {
      final controller = _mixedStatusController();
      await tester.pumpWidget(
        MaterialApp(home: InstancePickerScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      final ys = [
        for (final name in ['notes', 'gaviero', 'old', 'stale'])
          tester.getTopLeft(find.text(name)).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      expect(find.text('in use'), findsOneWidget);
      expect(find.text('online'), findsOneWidget);
      expect(find.text('offline'), findsNWidgets(2));
    });

    testWidgets('offline rows are grey and only they have a remove button', (
      tester,
    ) async {
      final controller = _mixedStatusController();
      await tester.pumpWidget(
        MaterialApp(home: InstancePickerScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      final disabled = Theme.of(
        tester.element(find.text('old')),
      ).disabledColor;
      ListTile tile(String id) =>
          tester.widget<ListTile>(find.byKey(ValueKey('instance-alpha-$id')));
      expect(tile('wOld').textColor, disabled);
      expect(tile('wStale').textColor, disabled);
      expect(tile('w1').textColor, isNull);
      expect(tile('w2').textColor, isNull);
      expect(find.byKey(const ValueKey('remove-alpha-wOld')), findsOneWidget);
      expect(find.byKey(const ValueKey('remove-alpha-wStale')), findsOneWidget);
      expect(find.byKey(const ValueKey('remove-alpha-w1')), findsNothing);
      expect(find.byKey(const ValueKey('remove-alpha-w2')), findsNothing);
    });

    testWidgets('remove button drops the offline row and refresh keeps it out', (
      tester,
    ) async {
      final controller = _mixedStatusController();
      await tester.pumpWidget(
        MaterialApp(home: InstancePickerScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-alpha-wOld')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(find.text('old'), findsNothing);
      await controller.refreshDirectory();
      await tester.pumpAndSettle();
      expect(find.text('old'), findsNothing);
      expect(find.text('stale'), findsOneWidget);
      expect(find.text('gaviero'), findsOneWidget);
      expect(find.text('notes'), findsOneWidget);
    });

    testWidgets('machine menu removes every offline row and nothing else', (
      tester,
    ) async {
      final controller = _mixedStatusController();
      await tester.pumpWidget(
        MaterialApp(home: InstancePickerScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('machine-menu-alpha')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove offline instances'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(find.text('old'), findsNothing);
      expect(find.text('stale'), findsNothing);
      expect(find.text('gaviero'), findsOneWidget);
      expect(find.text('notes'), findsOneWidget);
      expect(controller.instanceStore.doc.machines, hasLength(1));
    });

    testWidgets('no offline rows ⇒ no remove-offline menu item', (
      tester,
    ) async {
      final controller = _mixedStatusController(withOffline: false);
      await tester.pumpWidget(
        MaterialApp(home: InstancePickerScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('machine-menu-alpha')));
      await tester.pumpAndSettle();
      expect(find.text('Remove offline instances'), findsNothing);
      expect(find.text('Forget machine'), findsOneWidget);
    });
  });

  test('orderForPicker: no known activity falls back to status', () {
    final store = InstanceStore(kv: MemoryKv())
      ..doc = StoreDocument(
        machines: const [
          MachineRecord(host: 'alpha', token: 't', pairedAt: 'x',
              tlsCa: testTlsCa, relayHost: testRelayHost,
              relaySecret: testRelaySecret),
        ],
      );
    const off = InstanceRecord(
      machineHost: 'alpha', workspaceId: 'off', displayName: 'off', url: 'u0');
    const on = InstanceRecord(machineHost: 'alpha', workspaceId: 'on',
        displayName: 'on', url: 'u1', lastOnline: true);
    const used = InstanceRecord(machineHost: 'alpha', workspaceId: 'used',
        displayName: 'used', url: 'u2', lastOnline: true, inUse: true);
    const unknown = InstanceRecord(machineHost: 'alpha', workspaceId: 'unk',
        displayName: 'unk', url: 'u3', lastUnknown: true);
    final names = [
      for (final i in orderForPicker([off, unknown, on, used], store))
        i.displayName,
    ];
    expect(names, ['used', 'unk', 'on', 'off']);
  });

  test('orderForPicker mixes machines, latest activity first', () {
    final store = InstanceStore(kv: MemoryKv())
      ..doc = StoreDocument(
        machines: const [
          MachineRecord(host: 'alpha', token: 't', pairedAt: 'x',
              tlsCa: testTlsCa, relayHost: testRelayHost,
              relaySecret: testRelaySecret),
          MachineRecord(host: 'beta', token: 't', pairedAt: 'x',
              tlsCa: testTlsCa, relayHost: testRelayHost,
              relaySecret: testRelaySecret),
        ],
      );
    const quiet = InstanceRecord(machineHost: 'alpha', workspaceId: 'quiet',
        displayName: 'quiet', url: 'u0', lastOnline: true, inUse: true);
    // Opened most recently from this phone, but nothing happened there since.
    const oldActivity = InstanceRecord(machineHost: 'alpha',
        workspaceId: 'old', displayName: 'old', url: 'u1',
        lastOnline: true, lastUsed: '2026-11-12T11:00:00.000Z',
        lastActivity: '2026-11-01T10:00:00Z');
    const recentOffline = InstanceRecord(machineHost: 'beta',
        workspaceId: 'recentOff', displayName: 'recentOff', url: 'u2',
        lastActivity: '2026-11-12T09:00:00Z');
    const middle = InstanceRecord(machineHost: 'beta', workspaceId: 'mid',
        displayName: 'mid', url: 'u3', lastOnline: true,
        lastActivity: '2026-11-05T09:00:00Z');
    const neverOffline = InstanceRecord(machineHost: 'alpha',
        workspaceId: 'never', displayName: 'never', url: 'u4',
        lastUsed: '2026-11-12T12:00:00.000Z');
    final names = [
      for (final i in orderForPicker(
        [neverOffline, quiet, oldActivity, recentOffline, middle],
        store,
      ))
        i.displayName,
    ];
    // Activity beats status, machine and last use; the rest follow by status.
    expect(names, ['recentOff', 'mid', 'old', 'quiet', 'never']);
  });

  testWidgets('opening an instance does not reorder; its activity does',
      (tester) async {
    final controller = _controllerWith(_twoMachinesThreeInstances);
    await tester.pumpWidget(
      MaterialApp(home: InstancePickerScreen(controller: controller)),
    );
    double y(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(y('gaviero'), lessThan(y('flutter')));
    await tester.tap(find.text('flutter'));
    await tester.pump();
    final store = controller.instanceStore;
    const key = InstanceKey('beta', 'w3');
    expect(store.instance(key)?.lastUsed, isNotNull);
    expect(store.doc.lastInstance, key);
    await controller.disconnect();
    await tester.pump();
    // Visiting alone leaves it where status put it.
    expect(y('flutter'), greaterThan(y('notes')));
    expect(y('flutter'), greaterThan(y('gaviero')));

    // The desktop reports an event there: it moves to the top.
    await store.upsertInstance(
      store.instance(key)!.copyWith(lastActivity: '2026-11-12T10:00:00Z'),
    );
    await controller.refreshDirectory();
    await tester.pump();
    expect(y('flutter'), lessThan(y('notes')));
    expect(y('flutter'), lessThan(y('gaviero')));
    expect(find.text('Last activity 2026-11-12T10:00:00Z'), findsOneWidget);
  });
}

/// Machine `alpha` whose directory lists `gaviero` (online) and `notes`
/// (in use). `old` and `stale` are not listed and their probes fail, so a
/// refresh keeps them offline. Store order deliberately puts offline first.
RemoteHub _mixedStatusController({bool withOffline = true}) {
  const dirUrl = 'https://dir-alpha/v1/instances';
  final body = jsonEncode({
    'protocol_version': {'major': 1, 'minor': 1},
    'host': 'alpha',
    'generated_at': '2026-09-09T12:00:00Z',
    'instances': [
      for (final (id, name, inUse) in [
        ('w1', 'gaviero', false),
        ('w2', 'notes', true),
      ])
        {
          'instance_id': id,
          'workspace': {'id': id, 'display_name': name},
          'url': 'wss://$id-alpha/v1/ws',
          'port': 443,
          'tui_version': '0.1.0',
          'started_at': '2026-09-09T11:58:03Z',
          'client_connected': inUse,
        },
    ],
  });
  final store = InstanceStore(kv: MemoryKv())
    ..doc = StoreDocument(
      machines: const [
        MachineRecord(host: 'alpha', token: 't1', pairedAt: 'x',
            directoryUrl: dirUrl, tlsCa: testTlsCa, relayHost: testRelayHost,
            relaySecret: testRelaySecret),
      ],
      instances: [
        if (withOffline)
          const InstanceRecord(machineHost: 'alpha', workspaceId: 'wOld',
              displayName: 'old', url: 'wss://wOld-alpha/v1/ws'),
        const InstanceRecord(machineHost: 'alpha', workspaceId: 'w1',
            displayName: 'gaviero', url: 'wss://w1-alpha/v1/ws',
            lastOnline: true),
        if (withOffline)
          const InstanceRecord(machineHost: 'alpha', workspaceId: 'wStale',
              displayName: 'stale', url: 'wss://wStale-alpha/v1/ws'),
        const InstanceRecord(machineHost: 'alpha', workspaceId: 'w2',
            displayName: 'notes', url: 'wss://w2-alpha/v1/ws',
            lastOnline: true, inUse: true),
      ],
    );
  return RemoteHub(
    instanceStore: store,
    directoryClient: DirectoryClient(
      fetch: (url, token) async {
        if (url.toString() == dirUrl) return DirectoryFetchResult(200, body);
        throw StateError('unreachable');
      },
    ),
    connectionFactory: () => RemoteConnection(
      connector: (url, token) async {
        throw StateError('offline');
      },
    ),
  );
}
