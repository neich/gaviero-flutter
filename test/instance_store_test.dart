/// D2: InstanceStore persist, relay-only load, and 20-instance round-trip.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/kv.dart';
import 'package:gaviero_remote/src/services/secure_store.dart';
import 'package:gaviero_remote/src/state/controller.dart';
import 'package:gaviero_remote/src/transport/connection.dart';

import 'support/relay_machine.dart';

RemoteConnection _offlineConnection() =>
    RemoteConnection(connector: (url, token) async {
      throw StateError('offline');
    });

void main() {
  test('a stored machine without relay data is dropped with its instances',
      () async {
    final kv = MemoryKv({
      instancesV2Key: jsonEncode({
        'v': 2,
        'machines': [
          {'host': 'old', 'token': 't', 'paired_at': ''},
          {
            'host': 'desk',
            'token': 't',
            'paired_at': '',
            'tls_ca': testTlsCa,
            'relay_host': testRelayHost,
            'relay_secret': testRelaySecret,
          },
        ],
        'instances': [
          {'machine_host': 'old', 'display_name': 'a', 'url': 'wss://old/v1/ws'},
          {'machine_host': 'desk', 'display_name': 'b', 'url': 'wss://desk/v1/ws'},
        ],
        'last_instance': {'machine_host': 'old', 'workspace_id': null},
      }),
    });
    final store = InstanceStore(kv: kv);
    await store.load();
    expect(store.doc.machines.map((m) => m.host), ['desk']);
    expect(store.doc.instances.map((i) => i.machineHost), ['desk']);
    expect(store.doc.lastInstance, isNull);
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
      url: 'wss://a-host.example/v1/ws',
      token: 'first',
      workspace: 'a',
      machine: 'host.example',
      tlsCa: testTlsCa,
      relayHost: testRelayHost,
      relaySecret: testRelaySecret,
    ));
    await controller.pair(const PairingConfig(
      url: 'wss://b-host.example/v1/ws',
      token: 'rotated',
      workspace: 'b',
      machine: 'host.example',
      workspaceId: 'ws-b',
      tlsCa: testTlsCa,
      relayHost: testRelayHost,
      relaySecret: testRelaySecret,
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
      tlsCa: testTlsCa,
      relayHost: testRelayHost,
      relaySecret: testRelaySecret,
    ));
    for (var i = 0; i < 20; i++) {
      await store.upsertInstance(InstanceRecord(
        machineHost: 'h',
        workspaceId: 'ws-$i',
        displayName: 'workspace $i',
        url: 'wss://ws-$i-h/v1/ws',
      ));
    }
    final reloaded = InstanceStore(kv: kv);
    await reloaded.load();
    expect(reloaded.doc.instances, hasLength(20));
    expect(reloaded.doc.instances.last.displayName, 'workspace 19');
  });
}
