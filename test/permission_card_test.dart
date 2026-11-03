/// B6 verification (machine-verifiable part): a multi-question
/// AskUserQuestion answered through the UI produces `answers: [[i], [j,k]]`
/// on the wire — option indices, never a rebuilt tool input — and a plain
/// allow carries no `answers` key at all.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/protocol.dart';
import 'package:gaviero_remote/src/state/app_state.dart';
import 'package:gaviero_remote/src/state/controller.dart';
import 'package:gaviero_remote/src/transport/connection.dart';
import 'package:gaviero_remote/src/transport/socket.dart';
import 'package:gaviero_remote/src/ui/permission_card.dart';

final class CapturingSocket implements WsSocket {
  final _controller = StreamController<dynamic>();
  final sent = <Map<String, Object?>>[];

  @override
  int? closeCode;
  @override
  String? closeReason;

  @override
  Stream<dynamic> get frames => _controller.stream;

  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, Object?>);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_controller.isClosed) await _controller.close();
  }

  void serverSend(Map<String, Object?> envelope) =>
      _controller.add(jsonEncode(envelope));
}

const askRequest = PermissionRequest(
  convId: 'c1',
  requestId: 'req-1',
  toolName: 'AskUserQuestion',
  description: 'The agent is asking for input',
  input: {'display': 'only'},
  ask: Ask(questions: [
    AskQuestion(
      question: 'Which serializer?',
      header: 'Serializer',
      multiSelect: false,
      options: [
        AskOption(label: 'serde_json', description: 'existing'),
        AskOption(label: 'simd-json', description: 'faster'),
      ],
    ),
    AskQuestion(
      question: 'Which suites?',
      header: 'Tests',
      multiSelect: true,
      options: [
        AskOption(label: 'unit', description: ''),
        AskOption(label: 'integration', description: ''),
        AskOption(label: 'fuzz', description: ''),
        AskOption(label: 'bench', description: ''),
      ],
    ),
  ]),
);

Future<(RemoteController, CapturingSocket)> connectedController({
  List<String> capabilities = const [],
}) async {
  final socket = CapturingSocket();
  final controller = RemoteController(
    connection: RemoteConnection(connector: (url, token) async => socket),
    state: AppState(),
  );
  await controller.connection.start(Uri.parse('wss://h/v1/ws'), 't');
  socket.serverSend({
    'version': {'major': 1, 'minor': 0},
    'instance_id': 'i1',
    'seq': 1,
    'revision': 1,
    'type': 'hello',
    'payload': {
      'protocol_version': {'major': 1, 'minor': 0},
      'instance_id': 'i1',
      'tui_version': '0.1.0',
      'workspace': {'id': 'w', 'display_name': 'w'},
      'capabilities': capabilities,
      'confirm_required': <String>[],
      'allowed_slash_commands': <String>[],
      'limits': {
        'max_frame_bytes': 262144,
        'max_prompt_bytes': 131072,
        'command_rate_per_second': 10,
      },
    },
  });
  await Future<void>.delayed(Duration.zero);
  return (controller, socket);
}

void main() {
  testWidgets('multi-question ask answers as option indices', (tester) async {
    // Real-async setup: testWidgets runs in a fake-async zone where the
    // socket's stream delivery would otherwise never fire.
    final (controller, socket) =
        (await tester.runAsync(connectedController))!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child:
              PermissionCard(controller: controller, request: askRequest),
        ),
      ),
    ));

    // Single-select unanswered: the Answer button is disabled.
    final answerButton = find.widgetWithText(FilledButton, 'Answer');
    expect(tester.widget<FilledButton>(answerButton).onPressed, isNull);

    for (final label in ['simd-json', 'integration', 'bench']) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
    }

    await tester.ensureVisible(answerButton);
    await tester.tap(answerButton);
    await tester.pump();

    final frame = socket.sent.lastWhere(
        (f) => f['type'] == 'permission_decision');
    final payload = frame['payload'] as Map<String, Object?>;
    expect(payload['request_id'], 'req-1');
    expect(payload['allow'], isTrue);
    expect(payload['answers'], [
      [1],
      [1, 3]
    ]);
    expect(payload.containsKey('updated_input'), isFalse);
  });

  testWidgets('a plain allow sends no answers key', (tester) async {
    final (controller, socket) =
        (await tester.runAsync(connectedController))!;
    const plain = PermissionRequest(
      convId: 'c1',
      requestId: 'req-2',
      toolName: 'Bash',
      description: 'Run: cargo test',
      input: {'command': 'cargo test'},
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PermissionCard(controller: controller, request: plain),
        ),
      ),
    ));
    // The read-only input is visible.
    expect(find.textContaining('cargo test'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    await tester.pump();

    final frame = socket.sent.lastWhere(
        (f) => f['type'] == 'permission_decision');
    final payload = frame['payload'] as Map<String, Object?>;
    expect(payload['allow'], isTrue);
    expect(payload.containsKey('answers'), isFalse);
    expect(payload.containsKey('grant'), isFalse);
  });

  const mcpRequest = PermissionRequest(
    convId: 'c1',
    requestId: 'req-3',
    toolName: 'mcp__flutter__hot_reload',
    description: 'Hot reload the app',
    input: <String, Object?>{},
    mcpServer: 'flutter',
  );

  testWidgets('allow-server-for-this-prompt sends the turn grant',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(() =>
        connectedController(
            capabilities: [Capability.permissionTurnGrant])))!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PermissionCard(controller: controller, request: mcpRequest),
        ),
      ),
    ));

    final grant = find.text('All flutter tools (this prompt)');
    expect(grant, findsOneWidget);
    await tester.tap(grant);
    await tester.pump();

    final frame = socket.sent.lastWhere(
        (f) => f['type'] == 'permission_decision');
    final payload = frame['payload'] as Map<String, Object?>;
    expect(payload['request_id'], 'req-3');
    expect(payload['allow'], isTrue);
    expect(payload['grant'], 'mcp_server_turn');
  });

  testWidgets('no turn-grant option without the server capability',
      (tester) async {
    final (controller, _) = (await tester.runAsync(connectedController))!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PermissionCard(controller: controller, request: mcpRequest),
        ),
      ),
    ));
    expect(find.textContaining('this prompt'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Allow'), findsOneWidget);
  });

  // 1.6 `permission_grants`: the card offers exactly the listed grants, in
  // the desktop overlay's order, each labelled with its desktop key.
  const grantedMcp = PermissionRequest(
    convId: 'c1',
    requestId: 'req-4',
    toolName: 'mcp__flutter__hot_reload',
    description: 'Hot reload the app',
    input: <String, Object?>{},
    mcpServer: 'flutter',
    grants: [
      PermissionGrant.toolSession,
      PermissionGrant.mcpServerSession,
      PermissionGrant.mcpServerTurn,
      PermissionGrant.turnAll,
    ],
  );

  Future<CapturingSocket> pumpCard(
    WidgetTester tester,
    PermissionRequest request, {
    List<String> capabilities = const [
      Capability.permissionTurnGrant,
      Capability.permissionGrants,
    ],
  }) async {
    final (controller, socket) = (await tester.runAsync(
        () => connectedController(capabilities: capabilities)))!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PermissionCard(controller: controller, request: request),
        ),
      ),
    ));
    return socket;
  }

  Map<String, Object?> lastDecision(CapturingSocket socket) =>
      socket.sent.lastWhere((f) => f['type'] == 'permission_decision')[
          'payload'] as Map<String, Object?>;

  testWidgets('every listed grant is offered, in desktop order',
      (tester) async {
    await pumpCard(tester, grantedMcp);
    final labels = [
      'Allow for session',
      'All flutter tools',
      'All flutter tools (this prompt)',
      'Allow all (this prompt)',
    ];
    final tops = [
      for (final label in labels) tester.getTopLeft(find.text(label)).dy
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    // Desktop key badges: y / n on Allow / Deny, a / A / p on the grants.
    for (final key in ['y', 'n', 'a', 'A', 'p']) {
      expect(find.text(key), findsOneWidget, reason: key);
    }
  });

  for (final (label, wire) in [
    ('Allow for session', 'tool_session'),
    ('All flutter tools', 'mcp_server_session'),
    ('All flutter tools (this prompt)', 'mcp_server_turn'),
    ('Allow all (this prompt)', 'turn_all'),
  ]) {
    testWidgets('"$label" sends grant $wire', (tester) async {
      final socket = await pumpCard(tester, grantedMcp);
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
      final payload = lastDecision(socket);
      expect(payload['request_id'], 'req-4');
      expect(payload['allow'], isTrue);
      expect(payload['grant'], wire);
      expect(payload.containsKey('answers'), isFalse);
    });
  }

  testWidgets('a shell request offers allow-all only', (tester) async {
    const bash = PermissionRequest(
      convId: 'c1',
      requestId: 'req-5',
      toolName: 'Bash',
      description: 'Run: cargo test',
      input: {'command': 'cargo test'},
      grants: [PermissionGrant.turnAll],
    );
    final socket = await pumpCard(tester, bash);
    expect(find.text('Allow for session'), findsNothing);
    expect(find.text('Allow all (this prompt)'), findsOneWidget);
    await tester.tap(find.text('Allow all (this prompt)'));
    await tester.pump();
    expect(lastDecision(socket)['grant'], 'turn_all');
  });

  testWidgets('without the 1.6 capability, grants are not offered',
      (tester) async {
    await pumpCard(tester, grantedMcp,
        capabilities: const [Capability.permissionTurnGrant]);
    expect(find.text('Allow all (this prompt)'), findsNothing);
    expect(find.text('Allow for session'), findsNothing);
    // 1.4 fallback from mcp_server.
    expect(find.text('All flutter tools (this prompt)'), findsOneWidget);
  });

  testWidgets('hardware keys answer as on the desktop', (tester) async {
    final socket = await pumpCard(tester, grantedMcp);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(lastDecision(socket)['grant'], 'turn_all');
  });

  testWidgets('an unoffered key does nothing', (tester) async {
    const bash = PermissionRequest(
      convId: 'c1',
      requestId: 'req-6',
      toolName: 'Bash',
      description: 'Run: ls',
      input: {'command': 'ls'},
      grants: [PermissionGrant.turnAll],
    );
    final socket = await pumpCard(tester, bash);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(socket.sent.where((f) => f['type'] == 'permission_decision'),
        isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.pump();
    final payload = lastDecision(socket);
    expect(payload['allow'], isTrue);
    expect(payload.containsKey('grant'), isFalse);
  });
}
