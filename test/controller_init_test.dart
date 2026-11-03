/// Directory refresh before reconnecting, and notification targets.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/directory_client.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/kv.dart';
import 'package:gaviero_remote/src/state/controller.dart';
import 'package:gaviero_remote/src/transport/connection.dart';

import 'support/relay_machine.dart';

void main() {
  test(
    'onAppResumed reconnects when the directory reports a new url',
    () async {
      final store = InstanceStore(kv: MemoryKv());
      store.doc = StoreDocument(
        machines: const [
          MachineRecord(
            host: 'alpha',
            token: 't',
            directoryUrl: 'https://ws-alpha/v1/instances',
            pairedAt: 'x',
            tlsCa: testTlsCa,
            relayHost: testRelayHost,
            relaySecret: testRelaySecret,
          ),
        ],
        instances: const [
          InstanceRecord(
            machineHost: 'alpha',
            workspaceId: 'ws',
            displayName: 'gaviero',
            url: 'wss://ws1-alpha/v1/ws',
          ),
        ],
      );
      var fetches = 0;
      final connected = <Uri>[];
      final controller = RemoteController(
        instanceStore: store,
        directoryClient: DirectoryClient(
          fetch: (url, token) async {
            fetches++;
            return DirectoryFetchResult(
              200,
              jsonEncode({
                'protocol_version': {'major': 1, 'minor': 1},
                'host': 'alpha',
                'generated_at': '2026-09-09T15:31:04Z',
                'instances': [
                  {
                    'instance_id': 'i',
                    'workspace': {'id': 'ws', 'display_name': 'gaviero'},
                    'url': 'wss://ws2-alpha/v1/ws',
                    'port': 2,
                    'tui_version': '0.1.0',
                    'started_at': '2026-09-09T15:31:04Z',
                    'client_connected': false,
                  },
                ],
              }),
            );
          },
        ),
        connection: RemoteConnection(
          connector: (url, token) async {
            connected.add(url);
            throw StateError('offline');
          },
        ),
      );
      await controller.connect(store.doc.instances.single);
      await controller.connection.stop();
      connected.clear();
      await controller.onAppResumed();
      expect(fetches, 1);
      expect(connected, [Uri.parse('wss://ws2-alpha/v1/ws')]);
      await controller.connection.stop();
    },
  );

  test('openNotificationTarget disconnects when the instance is unknown',
      () async {
    final store = InstanceStore(kv: MemoryKv());
    store.doc = StoreDocument(
      machines: const [
        MachineRecord(
          host: 'alpha',
          token: 't',
          directoryUrl: 'https://ws-alpha/v1/instances',
          pairedAt: 'x',
          tlsCa: testTlsCa,
          relayHost: testRelayHost,
          relaySecret: testRelaySecret,
        ),
      ],
      instances: const [
        InstanceRecord(
          machineHost: 'alpha',
          workspaceId: 'ws',
          displayName: 'gaviero',
          url: 'wss://ws1-alpha/v1/ws',
        ),
      ],
    );
    final controller = RemoteController(
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
    await controller.connect(store.doc.instances.single);
    await controller.connection.stop();
    expect(controller.current, isNotNull);
    await controller.openNotificationTarget(
      machineHost: 'other.gaviero.example.com',
      workspaceId: 'nope',
      convId: 'c1',
    );
    expect(controller.current, isNull);
  });
}
