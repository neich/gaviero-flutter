/// 1.11 CLI runs: the HTTP client, the list order, the instance picker's
/// CLI runs tab and the run screen.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/cli_runs.dart';
import 'package:gaviero_remote/src/services/cli_runs_client.dart';
import 'package:gaviero_remote/src/services/directory_client.dart';
import 'package:gaviero_remote/src/services/instance_store.dart';
import 'package:gaviero_remote/src/services/kv.dart';
import 'package:gaviero_remote/src/state/hub.dart';
import 'package:gaviero_remote/src/transport/connection.dart';
import 'package:gaviero_remote/src/ui/cli_run_screen.dart';
import 'package:gaviero_remote/src/ui/cli_runs_tab.dart';
import 'package:gaviero_remote/src/ui/instance_picker_screen.dart';

import 'support/relay_machine.dart';

const _alpha = MachineRecord(
  host: 'alpha',
  token: 't1',
  directoryUrl: 'https://w1-alpha.relay/v1/instances',
  pairedAt: 'x',
  tlsCa: testTlsCa,
  relayHost: testRelayHost,
  relaySecret: testRelaySecret,
);

const _beta = MachineRecord(
  host: 'beta',
  token: 't2',
  pairedAt: 'x',
  tlsCa: testTlsCa,
  relayHost: testRelayHost,
  relaySecret: testRelaySecret,
);

Map<String, Object?> _summary(
  String id, {
  String state = 'running',
  String started = '2026-11-17T09:00:00Z',
  String script = 'deep_explore',
}) => {
  'id': id,
  'script': script,
  'folder': 'proj',
  'state': state,
  'phase': state == 'running' ? 'executing' : state,
  'running': state == 'running',
  'started_at': started,
  'updated_at': started,
  'cost_usd': 0.01,
  'counts': {'running': 1, 'queued': 0, 'done': 2, 'failed': 0},
  'agents': 3,
};

Map<String, Object?> _detail({
  String state = 'running',
  String selected = 'scout',
  String token = '7:3',
  List<String> lines = const ['Looking around'],
}) => {
  'run': {
    'id': 'r1',
    'run_id': 7,
    'script': 'deep_explore',
    'folder': 'proj',
    'state': state,
    'started_at': '2026-11-17T09:00:00Z',
    'phase': state == 'running' ? 'executing' : state,
    'running': state == 'running',
    'tier_current': 1,
    'tier_total': 2,
    'cost_usd': 0.0,
    'message': state == 'interrupted'
        ? 'gaviero-cli stopped without finishing this run.'
        : '',
    'counts': {'running': 1, 'queued': 1, 'done': 0, 'failed': 0},
    'agents': [
      {'id': 'scout', 'status': 'running', 'detail': '[Read x]',
       'tier': 'cheap', 'backend': 'claude:haiku', 'elapsed_ms': 3000,
       'branch': null, 'modified_files': <String>[]},
      {'id': 'writer', 'status': 'queued', 'detail': 'queued',
       'tier': 'expensive', 'backend': null, 'elapsed_ms': null,
       'branch': null, 'modified_files': <String>[]},
    ],
  },
  'selected_id': selected,
  'output': {
    'agent_id': selected,
    'token': token,
    'unchanged': false,
    'lines': [for (final l in lines) {'kind': 'text', 'text': l}],
    'truncated': false,
  },
};

/// A fetcher answering from [routes] (path → (status, body)); records every
/// URL and token it was asked for.
DirectoryFetcher _fetcher(
  Map<String, (int, Object?)> routes,
  List<(Uri, String)> asked,
) => (url, token) async {
  asked.add((url, token));
  final hit = routes[url.path];
  if (hit == null) throw StateError('offline');
  return DirectoryFetchResult(hit.$1, hit.$2 == null ? '' : jsonEncode(hit.$2));
};

void main() {
  group('client', () {
    test('origins: the directory route first, then each instance route', () {
      final origins = CliRunsClient.originsFor(_alpha, const [
        InstanceRecord(machineHost: 'alpha', workspaceId: 'w1', displayName: 'a',
            url: 'wss://w1-alpha.relay/v1/ws'),
        InstanceRecord(machineHost: 'alpha', workspaceId: 'w2', displayName: 'b',
            url: 'wss://w2-alpha.relay/v1/ws'),
        InstanceRecord(machineHost: 'beta', workspaceId: 'w3', displayName: 'c',
            url: 'wss://w3-beta.relay/v1/ws'),
      ]);
      expect(origins.map((u) => u.toString()), [
        'https://w1-alpha.relay',
        'https://w2-alpha.relay',
      ]);
    });

    test('list decodes the runs and sends the machine token', () async {
      final asked = <(Uri, String)>[];
      final client = CliRunsClient(fetch: _fetcher({
        '/v1/cli-runs': (200, {'host': 'alpha', 'runs': [
          _summary('r1'),
          _summary('r0', state: 'interrupted'),
          _summary('rx', state: 'something_new'),
        ]}),
      }, asked));
      final got = await client.listMachine(
        _alpha, [Uri.parse('https://w1-alpha.relay')]);
      expect(got.status, CliRunsStatus.ok);
      expect(got.runs.map((r) => r.id), ['r1', 'r0', 'rx']);
      expect(got.runs[0].running, isTrue);
      expect(got.runs[0].counts.done, 2);
      expect(got.runs[0].startedAt, DateTime.utc(2026, 11, 17, 9));
      expect(got.runs[1].state, CliRunState.interrupted);
      expect(got.runs[2].state, CliRunState.failed);
      expect(asked.single.$1.toString(), 'https://w1-alpha.relay/v1/cli-runs');
      expect(asked.single.$2, 't1');
    });

    test('an unreachable route falls through to the next; 404 = too old',
        () async {
      final asked = <(Uri, String)>[];
      var calls = 0;
      final client = CliRunsClient(fetch: (url, token) async {
        asked.add((url, token));
        calls++;
        if (calls == 1) throw StateError('offline');
        return const DirectoryFetchResult(404, '');
      });
      final got = await client.listMachine(_alpha, [
        Uri.parse('https://a.relay'),
        Uri.parse('https://b.relay'),
      ]);
      expect(got.status, CliRunsStatus.unsupported);
      expect(asked.map((a) => a.$1.host), ['a.relay', 'b.relay']);

      final down = await CliRunsClient(
        fetch: (url, token) async => throw StateError('offline'),
      ).listMachine(_alpha, [Uri.parse('https://a.relay')]);
      expect(down.status, CliRunsStatus.unreachable);

      final refused = await CliRunsClient(
        fetch: (url, token) async => const DirectoryFetchResult(401, ''),
      ).listMachine(_alpha, [Uri.parse('https://a.relay')]);
      expect(refused.status, CliRunsStatus.unauthorized);
    });

    test('read sends the agent and token, decodes the run, 404 = gone',
        () async {
      final asked = <(Uri, String)>[];
      final client = CliRunsClient(fetch: _fetcher({
        '/v1/cli-runs/r1': (200, _detail()),
        '/v1/cli-runs/gone': (404, null),
      }, asked));
      final origin = [Uri.parse('https://w1-alpha.relay')];
      final read = await client.read(_alpha, origin, 'r1',
          agentId: 'writer', outputToken: '7:2');
      expect(asked.last.$1.queryParameters,
          {'agent_id': 'writer', 'output_token': '7:2'});
      final run = read.snapshot!.run!;
      expect(run.id, 'r1');
      expect(run.folder, 'proj');
      expect(run.state, 'running');
      expect(run.runId, 7);
      expect(read.snapshot!.output!.lines.single.text, 'Looking around');

      await client.read(_alpha, origin, 'r1');
      expect(asked.last.$1.hasQuery, isFalse);

      final gone = await client.read(_alpha, origin, 'gone');
      expect(gone.missing, isTrue);
      expect(gone.snapshot, isNull);

      // An older listener's 404 does not hide the run a newer one serves.
      final mixed = await CliRunsClient(fetch: (url, token) async =>
          url.host == 'old.relay'
              ? const DirectoryFetchResult(404, '')
              : DirectoryFetchResult(200, jsonEncode(_detail())),
      ).read(_alpha, [Uri.parse('https://old.relay'), Uri.parse('https://new.relay')], 'r1');
      expect(mixed.missing, isFalse);
      expect(mixed.snapshot?.run?.id, 'r1');
    });
  });

  test('order: running first, then newest; times read local', () {
    final rows = orderCliRuns([
      MachineCliRuns(_alpha, CliRunsStatus.ok, [
        CliRunSummary.fromJson(_summary('old-done', state: 'completed',
            started: '2026-11-17T08:00:00Z')),
        CliRunSummary.fromJson(_summary('new-done', state: 'failed',
            started: '2026-11-17T10:00:00Z')),
      ]),
      MachineCliRuns(_beta, CliRunsStatus.ok, [
        CliRunSummary.fromJson(_summary('old-running',
            started: '2026-11-16T08:00:00Z')),
      ]),
    ]);
    expect(rows.map((r) => r.$2.id), ['old-running', 'new-done', 'old-done']);
    expect(rows.first.$1.host, 'beta');

    final at = DateTime(2026, 11, 17, 9, 5);
    expect(formatRunTime(at, now: DateTime(2026, 11, 17, 20)), '09:05');
    expect(formatRunTime(at, now: DateTime(2026, 11, 18)), '2026-11-17 09:05');
  });

  testWidgets('the picker has a CLI runs tab listing every machine',
      (tester) async {
    final asked = <(Uri, String)>[];
    final store = InstanceStore(kv: MemoryKv())
      ..doc = StoreDocument(
        machines: const [_alpha, _beta],
        instances: const [
          InstanceRecord(machineHost: 'beta', workspaceId: 'w3',
              displayName: 'flutter', url: 'wss://w3-beta.relay/v1/ws'),
        ],
      );
    final hub = RemoteHub(
      instanceStore: store,
      directoryClient: DirectoryClient(
        fetch: (url, token) async => const DirectoryFetchResult(404, ''),
      ),
      cliRunsClient: CliRunsClient(fetch: (url, token) async {
        asked.add((url, token));
        if (url.host == 'w1-alpha.relay') {
          return DirectoryFetchResult(200, jsonEncode({
            'host': 'alpha',
            'runs': [_summary('r1')],
          }));
        }
        // beta runs an older Gaviero.
        return const DirectoryFetchResult(404, '');
      }),
      connectionFactory: () => RemoteConnection(
        connector: (url, token) async => throw StateError('offline'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: InstancePickerScreen(controller: hub)),
    );
    await tester.pump();
    expect(find.text('flutter'), findsOneWidget, reason: 'instances tab first');
    expect(asked, isEmpty, reason: 'the CLI tab is not polled until shown');

    await tester.tap(find.byKey(const Key('tab-cli-runs')));
    // A running row spins forever: pump past the tab animation instead of
    // settling.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byKey(const ValueKey('cli-run-r1')), findsOneWidget);
    expect(find.text('deep_explore'), findsOneWidget);
    expect(find.text('proj · alpha'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('cli-run-status-r1'))).data,
      contains('executing'),
    );
    expect(find.byKey(const ValueKey('cli-runs-note-beta')), findsOneWidget);
    expect(find.textContaining('Update Gaviero'), findsOneWidget);
    expect(asked.map((a) => a.$2).toSet(), {'t1', 't2'});

    // Leaving the tab stops polling.
    await tester.tap(find.byKey(const Key('tab-instances')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final before = asked.length;
    await tester.pump(const Duration(seconds: 7));
    expect(asked.length, before);
  });

  testWidgets('a CLI run shows like the Swarm section and follows the tap',
      (tester) async {
    final asked = <Uri>[];
    var state = 'running';
    final client = CliRunsClient(fetch: (url, token) async {
      asked.add(url);
      final agent = url.queryParameters['agent_id'];
      return DirectoryFetchResult(200, jsonEncode(_detail(
        state: state,
        selected: agent ?? 'scout',
        token: agent == null ? '7:3' : '7:1',
        lines: [agent == null ? 'Looking around' : 'Writing'],
      )));
    });
    await tester.pumpWidget(MaterialApp(
      home: CliRunScreen(
        client: client,
        machine: _alpha,
        origins: [Uri.parse('https://w1-alpha.relay')],
        summary: CliRunSummary.fromJson(_summary('r1')),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('proj · alpha'), findsOneWidget);
    expect(find.byKey(const Key('swarm-agent-scout')), findsOneWidget);
    expect(find.byKey(const Key('swarm-agent-writer')), findsOneWidget);
    expect(find.textContaining('Looking around'), findsOneWidget);
    expect(find.text('following the run'), findsOneWidget);

    // The next poll names the output it has.
    await tester.pump(const Duration(seconds: 1));
    expect(asked.last.queryParameters['output_token'], '7:3');

    await tester.tap(find.byKey(const Key('swarm-agent-writer')));
    await tester.pump();
    await tester.pump();
    expect(asked.last.queryParameters['agent_id'], 'writer');
    expect(find.textContaining('Writing'), findsOneWidget);
    expect(find.text('following the run'), findsNothing);

    // An interrupted run says so and stops being polled.
    state = 'interrupted';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('interrupted'), findsOneWidget);
    expect(find.textContaining('stopped without finishing'), findsOneWidget);
    final settled = asked.length;
    await tester.pump(const Duration(seconds: 3));
    expect(asked.length, settled);

    await tester.pumpWidget(const SizedBox());
  });
}
