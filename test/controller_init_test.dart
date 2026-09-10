/// Launch reconnect must refresh the directory before using a stored URL,
/// so a TUI that fell forward one port is followed.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/version.dart';
import 'package:gaviero_remote/src/services/directory_client.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/kv.dart';
import 'package:gaviero_remote/src/state/controller.dart';
import 'package:gaviero_remote/src/transport/connection.dart';

void main() {
  test('initialize follows a stored instance that moved port', () async {
    final kv = MemoryKv();
    final store = InstanceStore(kv: kv);
    store.doc = StoreDocument(
      machines: const [
        MachineRecord(
          host: 'neichtop.tail.net',
          token: 't',
          directoryUrl: 'https://neichtop.tail.net:49151/v1/instances',
          pairedAt: 'x',
        ),
      ],
      instances: const [
        InstanceRecord(
          machineHost: 'neichtop.tail.net',
          workspaceId: '0b7d245998c0e8c3',
          displayName: 'gaviero',
          url: 'wss://neichtop.tail.net:52093/v1/ws',
        ),
      ],
      lastInstance: const InstanceKey('neichtop.tail.net', '0b7d245998c0e8c3'),
    );
    await store.persist();

    final connected = <Uri>[];
    final controller = RemoteController(
      instanceStore: store,
      directoryClient: DirectoryClient(
        fetch: (url, token) async {
          expect(url.port, defaultDirectoryPort);
          return DirectoryFetchResult(
            200,
            jsonEncode({
              'protocol_version': {'major': 1, 'minor': 1},
              'host': 'neichtop.tail.net',
              'generated_at': '2026-09-09T15:31:04Z',
              'instances': [
                {
                  'instance_id': 'live',
                  'workspace': {
                    'id': '0b7d245998c0e8c3',
                    'display_name': 'gaviero',
                  },
                  'url': 'wss://neichtop.tail.net:52094/v1/ws',
                  'port': 52094,
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

    expect(await controller.initialize(), isTrue);
    expect(connected, [Uri.parse('wss://neichtop.tail.net:52094/v1/ws')]);
    expect(
      store
          .instance(const InstanceKey('neichtop.tail.net', '0b7d245998c0e8c3'))!
          .url,
      'wss://neichtop.tail.net:52094/v1/ws',
    );
    await controller.connection.stop();
  });

  test(
    'onAppResumed reconnects when the directory reports a new url',
    () async {
      final store = InstanceStore(kv: MemoryKv());
      store.doc = StoreDocument(
        machines: const [
          MachineRecord(
            host: 'alpha',
            token: 't',
            directoryUrl: 'https://alpha:49151/v1/instances',
            pairedAt: 'x',
          ),
        ],
        instances: const [
          InstanceRecord(
            machineHost: 'alpha',
            workspaceId: 'ws',
            displayName: 'gaviero',
            url: 'wss://alpha:1/v1/ws',
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
                    'url': 'wss://alpha:2/v1/ws',
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
      expect(connected, [Uri.parse('wss://alpha:2/v1/ws')]);
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
          directoryUrl: 'https://alpha:49151/v1/instances',
          pairedAt: 'x',
        ),
      ],
      instances: const [
        InstanceRecord(
          machineHost: 'alpha',
          workspaceId: 'ws',
          displayName: 'gaviero',
          url: 'wss://alpha:1/v1/ws',
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
      machineHost: 'other.tail.net',
      workspaceId: 'nope',
      convId: 'c1',
    );
    expect(controller.current, isNull);
  });
}
