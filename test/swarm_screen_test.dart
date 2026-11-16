import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/swarm.dart';
import 'package:gaviero_remote/src/ui/swarm_screen.dart';

import 'every_tab_test.dart' show connected;

Map<String, Object?> _agent(
  String id,
  String status, {
  String detail = '',
  String? error,
  String? tier,
  String? backend,
  int? elapsedMs,
  String? branch,
  List<String> files = const [],
}) => {
  'id': id,
  'status': status,
  'error': error,
  'detail': detail,
  'tier': tier,
  'backend': backend,
  'elapsed_ms': elapsedMs,
  'branch': branch,
  'modified_files': files,
};

Map<String, Object?> _run({
  int runId = 1,
  String phase = 'running',
  bool running = true,
  String message = '',
  required List<Map<String, Object?>> agents,
}) => {
  'run_id': runId,
  'script': 'deep_explore',
  'phase': phase,
  'running': running,
  'tier_current': 1,
  'tier_total': 2,
  'cost_usd': 0.0421,
  'message': message,
  'counts': {
    'running': agents.where((a) => a['status'] == 'running').length,
    'queued': agents.where((a) => a['status'] == 'queued').length,
    'done': agents.where((a) => a['status'] == 'completed').length,
    'failed': agents.where((a) => a['status'] == 'failed').length,
  },
  'agents': agents,
};

void main() {
  test('the request_swarm result decodes; unknown values degrade', () {
    final snapshot = SwarmSnapshot.fromJson({
      'run': _run(agents: [
        _agent('scout', 'running', tier: 'cheap', elapsedMs: 61000),
        _agent('writer', 'paused'),
      ]),
      'selected_id': 'scout',
      'output': {
        'agent_id': 'scout',
        'token': '1:4',
        'unchanged': false,
        'lines': [
          {'kind': 'status', 'text': 'Running: x'},
          {'kind': 'thinking', 'text': 'hmm'},
        ],
        'truncated': true,
      },
    });
    final run = snapshot.run!;
    expect(run.script, 'deep_explore');
    expect(run.costUsd, closeTo(0.0421, 1e-9));
    expect(run.agents[0].elapsed, const Duration(seconds: 61));
    expect(run.agents[1].status, SwarmAgentStatus.queued);
    expect(snapshot.output!.lines[1].kind, SwarmLineKind.text);
    expect(snapshot.output!.truncated, isTrue);
    expect(formatElapsed(const Duration(seconds: 61)), '1m1s');
    expect(formatElapsed(const Duration(minutes: 62)), '1h2m');
    final idle = SwarmSnapshot.fromJson(
        {'run': null, 'selected_id': null, 'output': null});
    expect(idle.run, isNull);
  });

  testWidgets('the swarm screen follows the desktop, then the agent tapped',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['swarm_activity']),
    ))!;
    var seq = 2;
    void reply(Object? result) {
      final request = socket.sent.lastWhere((f) => f['type'] == 'request_swarm');
      socket.serverSend({
        'version': {'major': 1, 'minor': 10},
        'instance_id': 'i1', 'seq': seq++, 'revision': 1,
        'type': 'command_result',
        'payload': {
          'command_id': request['command_id'], 'status': 'completed',
          'result': result,
        },
      });
    }

    Map<String, Object?> lastPayload() => socket.sent
        .lastWhere((f) => f['type'] == 'request_swarm')['payload']
        as Map<String, Object?>;

    await tester.pumpWidget(MaterialApp(home: SwarmScreen(controller: controller)));
    // First poll: no agent chosen, no token.
    expect(lastPayload(), <String, Object?>{});
    reply({'run': null, 'selected_id': null, 'output': null});
    await tester.pump();
    expect(find.textContaining('No swarm has run'), findsOneWidget);

    final agents = [
      _agent('scout', 'running',
          detail: '[Read src/main.rs]', tier: 'cheap',
          backend: 'claude:haiku', elapsedMs: 12000),
      _agent('writer', 'queued', detail: 'queued', tier: 'expensive'),
    ];
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    reply({
      'run': _run(agents: agents, message: 'prepared'),
      'selected_id': 'scout',
      'output': {
        'agent_id': 'scout', 'token': '1:3', 'unchanged': false,
        'lines': [
          {'kind': 'status', 'text': 'Running: reading'},
          {'kind': 'text', 'text': 'Looking at main'},
          {'kind': 'tool_call', 'text': '[Read src/main.rs]'},
        ],
        'truncated': false,
      },
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('deep_explore'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text('Tier 1/2'), findsOneWidget);
    expect(find.text('~\$0.042'), findsOneWidget);
    expect(find.text('prepared'), findsOneWidget);
    expect(find.text('1 running'), findsOneWidget);
    expect(find.text('1 queued'), findsOneWidget);
    expect(find.text('scout · claude:haiku'), findsOneWidget);
    expect(find.text('following the computer'), findsOneWidget);
    expect(find.textContaining('Looking at main'), findsOneWidget);
    expect(find.textContaining('12s'), findsOneWidget);

    // The next poll names the output it has; unchanged output is kept.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(lastPayload(), {'output_token': '1:3'});
    reply({
      'run': _run(agents: agents),
      'selected_id': 'scout',
      'output': {'agent_id': 'scout', 'token': '1:3', 'unchanged': true},
    });
    await tester.pump();
    expect(find.textContaining('Looking at main'), findsOneWidget);

    // Tapping an agent asks for its output in full.
    await tester.tap(find.byKey(const Key('swarm-agent-writer')));
    await tester.pump();
    expect(lastPayload(), {'agent_id': 'writer'});
    expect(find.text('Queued. Output appears when it starts.'), findsOneWidget);
    expect(find.text('following the computer'), findsNothing);
    reply({
      'run': _run(agents: agents),
      'selected_id': 'writer',
      'output': {
        'agent_id': 'writer', 'token': '1:0', 'unchanged': false,
        'lines': <Object?>[], 'truncated': false,
      },
    });
    await tester.pump();
    expect(find.textContaining('Looking at main'), findsNothing);

    // Back to following the computer.
    await tester.tap(find.byKey(const Key('swarm-follow-desktop')));
    await tester.pump();
    expect(lastPayload(), <String, Object?>{});

    // Nothing reaches the server that could change the run.
    expect(
      socket.sent.map((f) => f['type']).toSet()
        ..removeAll({'client_hello', 'request_swarm', 'request_snapshot'}),
      isEmpty,
    );
    await tester.runAsync(() => controller.connection.stop());
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('a finished run shows failures, the branch and changed files',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['swarm_activity']),
    ))!;
    await tester.pumpWidget(MaterialApp(home: SwarmScreen(controller: controller)));
    final request = socket.sent.lastWhere((f) => f['type'] == 'request_swarm');
    socket.serverSend({
      'version': {'major': 1, 'minor': 10},
      'instance_id': 'i1', 'seq': 2, 'revision': 1,
      'type': 'command_result',
      'payload': {
        'command_id': request['command_id'], 'status': 'completed',
        'result': {
          'run': _run(
            phase: 'completed with failures',
            running: false,
            agents: [
              _agent('scout', 'completed', detail: 'Modified 2 files',
                  branch: 'gaviero/scout', files: ['a.rs', 'b.rs'],
                  elapsedMs: 3000),
              _agent('writer', 'failed', error: 'not run'),
            ],
          ),
          'selected_id': 'scout',
          'output': {
            'agent_id': 'scout', 'token': '1:9', 'unchanged': false,
            'lines': [
              {'kind': 'file_change', 'text': '[wrote a.rs +3 -1]'},
            ],
            'truncated': true,
          },
        },
      },
    });
    await tester.pump();
    expect(find.text('completed with failures'), findsOneWidget);
    expect(find.text('not run'), findsOneWidget);
    expect(find.text('Branch gaviero/scout · 2 files: a.rs, b.rs'), findsOneWidget);
    expect(find.textContaining('Earlier output is not shown.'), findsOneWidget);
    // Expanding the output hides the agent rows.
    await tester.tap(find.byKey(const Key('swarm-expand')));
    await tester.pump();
    expect(find.byKey(const Key('swarm-agent-writer')), findsNothing);
    await tester.runAsync(() => controller.connection.stop());
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('older servers show an update message and receive no requests',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(() => connected()))!;
    await tester.pumpWidget(MaterialApp(home: SwarmScreen(controller: controller)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Update Gaviero'), findsOneWidget);
    expect(socket.sent.where((f) => f['type'] == 'request_swarm'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.connection.stop());
    controller.dispose();
  });
}
