/// B6 verification (machine-verifiable part): a multi-question
/// AskUserQuestion answered through the UI produces `answers: [[i], [j,k]]`
/// on the wire — option indices, never a rebuilt tool input — and a plain
/// allow carries no `answers` key at all.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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

Future<(RemoteController, CapturingSocket)> connectedController() async {
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
      'capabilities': <String>[],
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
  });
}
