/// D2: InstanceStore migration, persist, and 20-instance round-trip.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/kv.dart';
import 'package:gaviero_remote/src/services/secure_store.dart';
import 'package:gaviero_remote/src/state/controller.dart';
import 'package:gaviero_remote/src/transport/connection.dart';

RemoteConnection _offlineConnection() =>
    RemoteConnection(connector: (url, token) async {
      throw StateError('offline');
    });

void main() {
  test('legacy pairing keys migrate once into instances_v2 and are deleted',
      () async {
    final kv = MemoryKv({
      legacyUrlKey: 'wss://host.tailnet.ts.net:4443/v1/ws',
      legacyTokenKey: 'SECRET',
      legacyWorkspaceKey: 'gaviero',
    });
    final store = InstanceStore(kv: kv);
    await store.load();
    expect(store.doc.machines, hasLength(1));
    expect(store.doc.machines.single.host, 'host.tailnet.ts.net');
    expect(store.doc.machines.single.token, 'SECRET');
    expect(store.doc.instances, hasLength(1));
    expect(store.doc.instances.single.displayName, 'gaviero');
    expect(store.doc.instances.single.url,
        'wss://host.tailnet.ts.net:4443/v1/ws');
    expect(kv.map.containsKey(legacyUrlKey), isFalse);
    expect(kv.map.containsKey(legacyTokenKey), isFalse);
    expect(kv.map.containsKey(legacyWorkspaceKey), isFalse);
    expect(kv.map.containsKey(instancesV2Key), isTrue);

    final machines = store.doc.machines.length;
    final instances = store.doc.instances.length;
    await store.load();
    expect(store.doc.machines, hasLength(machines));
    expect(store.doc.instances, hasLength(instances));
  });

  test('pair() for an existing machine host updates the token in place',
      () async {
    final store = InstanceStore(kv: MemoryKv());
    await store.load();
    final controller = RemoteController(
      instanceStore: store,
      connection: _offlineConnection(),
    );
    await controller.pair(const PairingConfig(
      url: 'wss://host.example:1/v1/ws',
      token: 'first',
      workspace: 'a',
      machine: 'host.example',
    ));
    await controller.pair(const PairingConfig(
      url: 'wss://host.example:2/v1/ws',
      token: 'rotated',
      workspace: 'b',
      machine: 'host.example',
      workspaceId: 'ws-b',
    ));
    await controller.connection.stop();
    expect(store.doc.machines, hasLength(1));
    expect(store.doc.machines.single.token, 'rotated');
    expect(store.doc.machines.single.needsPairing, isFalse);
  });

  test('twenty instances persist and reload without truncation', () async {
    final kv = MemoryKv();
    final store = InstanceStore(kv: kv);
    await store.upsertMachine(const MachineRecord(
      host: 'h',
      token: 't',
      pairedAt: '2026-09-09T00:00:00Z',
    ));
    for (var i = 0; i < 20; i++) {
      await store.upsertInstance(InstanceRecord(
        machineHost: 'h',
        workspaceId: 'ws-$i',
        displayName: 'workspace $i',
        url: 'wss://h:${50000 + i}/v1/ws',
      ));
    }
    final reloaded = InstanceStore(kv: kv);
    await reloaded.load();
    expect(reloaded.doc.instances, hasLength(20));
    expect(reloaded.doc.instances.last.displayName, 'workspace 19');
  });
}
