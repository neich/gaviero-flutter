/// D2: DirectoryClient.refresh — union, offline leftover, 404/401, timeout.
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/directory_client.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/kv.dart';
import 'package:gaviero_remote/src/protocol/version.dart';

String _dirBody({
  required String host,
  required List<Map<String, Object?>> instances,
}) => jsonEncode({
  'protocol_version': {'major': 1, 'minor': 1},
  'host': host,
  'generated_at': '2026-09-09T12:00:00Z',
  'instances': instances,
});

Map<String, Object?> _info({
  required String id,
  required String workspaceId,
  required String name,
  required String url,
  required int port,
  bool inUse = false,
  String startedAt = '2026-09-09T11:58:03Z',
}) => {
  'instance_id': id,
  'workspace': {'id': workspaceId, 'display_name': name},
  'url': url,
  'port': port,
  'tui_version': '0.1.0',
  'started_at': startedAt,
  'client_connected': inUse,
};

InstanceStore _storeWith(
  List<MachineRecord> machines, [
  List<InstanceRecord> instances = const [],
]) {
  final store = InstanceStore(kv: MemoryKv());
  store.doc = StoreDocument(machines: machines, instances: instances);
  return store;
}

void main() {
  test('refresh unions the directory with per-instance probes', () async {
    final store = _storeWith(
      [
        const MachineRecord(
          host: 'alpha',
          token: 't',
          directoryUrl: 'https://alpha:49151/v1/instances',
          pairedAt: 'x',
        ),
      ],
      const [
        InstanceRecord(
          machineHost: 'alpha',
          workspaceId: 'old',
          displayName: 'old-ws',
          url: 'wss://alpha:1/v1/ws',
        ),
      ],
    );
    final client = DirectoryClient(
      fetch: (url, token) async {
        if (url.port == defaultDirectoryPort) {
          return DirectoryFetchResult(
            200,
            _dirBody(
              host: 'alpha',
              instances: [
                _info(
                  id: 'a',
                  workspaceId: 'new',
                  name: 'new-ws',
                  url: 'wss://alpha:2/v1/ws',
                  port: 2,
                ),
              ],
            ),
          );
        }
        return const DirectoryFetchResult(404, '');
      },
    );
    await client.refresh(store);
    expect(store.doc.instances.map((i) => i.workspaceId).toSet(), {
      'old',
      'new',
    });
    expect(
      store.instance(const InstanceKey('alpha', 'new'))!.lastOnline,
      isTrue,
    );
    expect(
      store.instance(const InstanceKey('alpha', 'old'))!.lastUnknown,
      isTrue,
    );
  });

  test('an instance absent from this round stays and is offline', () async {
    final store = _storeWith(
      [
        const MachineRecord(
          host: 'alpha',
          token: 't',
          directoryUrl: 'https://alpha:49151/v1/instances',
          pairedAt: 'x',
        ),
      ],
      const [
        InstanceRecord(
          machineHost: 'alpha',
          workspaceId: 'gone',
          displayName: 'gone',
          url: 'wss://alpha:9/v1/ws',
          lastOnline: true,
        ),
      ],
    );
    final client = DirectoryClient(
      fetch: (url, token) async {
        if (url.port == defaultDirectoryPort) {
          return DirectoryFetchResult(
            200,
            _dirBody(host: 'alpha', instances: []),
          );
        }
        throw Exception('connection refused');
      },
    );
    await client.refresh(store);
    final leftover = store.instance(const InstanceKey('alpha', 'gone'))!;
    expect(leftover.displayName, 'gone');
    expect(leftover.lastOnline, isFalse);
    expect(store.chipFor(leftover), InstanceChip.offline);
  });

  test('404 marks the probed instance unknown, still connectable', () async {
    final store = _storeWith(
      [const MachineRecord(host: 'legacy', token: 't', pairedAt: 'x')],
      const [
        InstanceRecord(
          machineHost: 'legacy',
          workspaceId: 'ws',
          displayName: 'one-oh',
          url: 'wss://legacy:4443/v1/ws',
        ),
      ],
    );
    final client = DirectoryClient(
      fetch: (url, token) async => const DirectoryFetchResult(404, ''),
    );
    await client.refresh(store);
    final inst = store.instance(const InstanceKey('legacy', 'ws'))!;
    expect(store.chipFor(inst), InstanceChip.unknown);
    expect(store.doc.instances, hasLength(1));
  });

  test('401 flags the machine and deletes nothing', () async {
    final store = _storeWith(
      [
        const MachineRecord(
          host: 'alpha',
          token: 'dead',
          directoryUrl: 'https://alpha:49151/v1/instances',
          pairedAt: 'x',
        ),
      ],
      const [
        InstanceRecord(
          machineHost: 'alpha',
          workspaceId: 'ws',
          displayName: 'keep-me',
          url: 'wss://alpha:1/v1/ws',
        ),
      ],
    );
    final client = DirectoryClient(
      fetch: (url, token) async => const DirectoryFetchResult(401, ''),
    );
    await client.refresh(store);
    expect(store.machine('alpha')!.needsPairing, isTrue);
    expect(store.doc.instances, hasLength(1));
    expect(store.doc.instances.single.displayName, 'keep-me');
    expect(
      store.chipFor(store.doc.instances.single),
      InstanceChip.needsPairing,
    );
  });

  test('duplicate workspace_id keeps the newest started_at url', () async {
    final store = _storeWith([
      const MachineRecord(
        host: 'alpha',
        token: 't',
        directoryUrl: 'https://alpha:49151/v1/instances',
        pairedAt: 'x',
      ),
    ]);
    final client = DirectoryClient(
      fetch: (url, token) async {
        return DirectoryFetchResult(
          200,
          _dirBody(
            host: 'alpha',
            instances: [
              _info(
                id: 'old',
                workspaceId: 'ws',
                name: 'gaviero',
                url: 'wss://alpha:52093/v1/ws',
                port: 52093,
                startedAt: '2026-09-09T15:00:00Z',
              ),
              _info(
                id: 'new',
                workspaceId: 'ws',
                name: 'gaviero',
                url: 'wss://alpha:52094/v1/ws',
                port: 52094,
                startedAt: '2026-09-09T15:31:04Z',
              ),
            ],
          ),
        );
      },
    );
    await client.refresh(store);
    final inst = store.instance(const InstanceKey('alpha', 'ws'))!;
    expect(inst.url, 'wss://alpha:52094/v1/ws');
    expect(store.doc.instances, hasLength(1));
  });

  test('port window finds the instance when the stored port is dead', () async {
    final store = _storeWith(
      [const MachineRecord(host: 'alpha', token: 't', pairedAt: 'x')],
      const [
        InstanceRecord(
          machineHost: 'alpha',
          workspaceId: 'ws',
          displayName: 'gaviero',
          url: 'wss://alpha:52093/v1/ws',
        ),
      ],
    );
    final client = DirectoryClient(
      fetch: (url, token) async {
        if (url.port == 52093) {
          throw Exception('connection refused');
        }
        if (url.port == 52094) {
          return DirectoryFetchResult(
            200,
            _dirBody(
              host: 'alpha',
              instances: [
                _info(
                  id: 'live',
                  workspaceId: 'ws',
                  name: 'gaviero',
                  url: 'wss://alpha:52094/v1/ws',
                  port: 52094,
                ),
              ],
            ),
          );
        }
        return const DirectoryFetchResult(404, '');
      },
    );
    await client.refresh(store);
    final inst = store.instance(const InstanceKey('alpha', 'ws'))!;
    expect(inst.url, 'wss://alpha:52094/v1/ws');
    expect(inst.lastOnline, isTrue);
    expect(inst.lastUnknown, isFalse);
  });

  test('a 3s timeout on one machine does not delay another', () {
    fakeAsync((async) {
      final store = _storeWith([
        const MachineRecord(
          host: 'slow',
          token: 't',
          directoryUrl: 'https://slow:49151/v1/instances',
          pairedAt: 'x',
        ),
        const MachineRecord(
          host: 'fast',
          token: 't',
          directoryUrl: 'https://fast:49151/v1/instances',
          pairedAt: 'x',
        ),
      ]);
      var fastDone = false;
      final client = DirectoryClient(
        fetch: (url, token) async {
          if (url.host == 'slow') {
            await Future<void>.delayed(const Duration(seconds: 30));
            return const DirectoryFetchResult(200, '{}');
          }
          fastDone = true;
          return DirectoryFetchResult(
            200,
            _dirBody(
              host: 'fast',
              instances: [
                _info(
                  id: 'f',
                  workspaceId: 'fw',
                  name: 'fast-ws',
                  url: 'wss://fast:1/v1/ws',
                  port: 1,
                ),
              ],
            ),
          );
        },
      );
      final future = client.refresh(store);
      async.elapse(const Duration(milliseconds: 100));
      expect(fastDone, isTrue);
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      var completed = false;
      future.then((_) => completed = true);
      async.flushMicrotasks();
      expect(completed, isTrue);
      expect(
        store.instance(const InstanceKey('fast', 'fw'))?.lastOnline,
        isTrue,
      );
    });
  });
}
