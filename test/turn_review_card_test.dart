/// Turn review (protocol 1.2) in the chat view: the card shows only on a
/// `turn_review` server, lists files with A/M/D badges and flags, sends
/// absolute whole-file actions (`path` only for per-file ones), disables
/// Revert for a non-revertible file, holds prompts (not slash lines) while
/// pending, highlights a cancelled turn, and summarizes a resolution.
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
import 'package:gaviero_remote/src/ui/chat_screen.dart';
import 'package:gaviero_remote/src/ui/turn_review_card.dart';

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

int _seq = 1;

Map<String, Object?> serverFrame(String type, Map<String, Object?> payload) =>
    {
      'version': {'major': 1, 'minor': 2},
      'instance_id': 'i1',
      'seq': _seq++,
      'revision': 1,
      'type': type,
      'payload': payload,
    };

Future<(RemoteController, CapturingSocket)> connected({
  List<String> capabilities = const ['turn_review'],
  List<String> confirmRequired = const [],
  List<String> allowedSlash = const ['/lite'],
}) async {
  _seq = 1;
  final socket = CapturingSocket();
  final controller = RemoteController(
    connection: RemoteConnection(connector: (url, token) async => socket),
    state: AppState(),
  );
  await controller.connection.start(Uri.parse('wss://h/v1/ws'), 't');
  socket.serverSend(serverFrame('hello', {
    'protocol_version': {'major': 1, 'minor': 2},
    'instance_id': 'i1',
    'tui_version': '0.1.0',
    'workspace': {'id': 'w', 'display_name': 'w'},
    'capabilities': capabilities,
    'confirm_required': confirmRequired,
    'allowed_slash_commands': allowedSlash,
    'limits': {
      'max_frame_bytes': 262144,
      'max_prompt_bytes': 131072,
      'command_rate_per_second': 10,
    },
  }));
  await Future<void>.delayed(Duration.zero);
  return (controller, socket);
}

ServerEnvelope env(ServerPayload payload) => ServerEnvelope(
      version: protocolVersion,
      instanceId: 'i1',
      seq: 100,
      revision: 1,
      payload: payload,
    );

const _summary = ConversationSummary(
  convId: 'c1',
  convRevision: 1,
  title: 'Chat',
  isStreaming: false,
  autoApprove: false,
);

Snapshot snapshotWith(List<TurnReview> reviews) => Snapshot(
      revision: 1,
      conversations: const [_summary],
      activeId: 'c1',
      activeConversation: const ConversationState(
        summary: _summary,
        messages: [],
        oldestSeq: 0,
        hasOlderMessages: false,
      ),
      openPermissions: const [],
      openProposals: const [],
      settings: const RemoteSettings(),
      openTurnReviews: reviews,
    );

TurnReview review({TurnOutcome outcome = TurnOutcome.completed}) => TurnReview(
      turnId: 'turn-1',
      convId: 'c1',
      outcome: outcome,
      files: const [
        TurnReviewFile(
          path: 'src/parser.rs',
          change: TurnFileChange.modified,
          decision: TurnFileDecision.pending,
          revertible: true,
          binary: false,
        ),
        TurnReviewFile(
          path: 'assets/big.bin',
          change: TurnFileChange.added,
          decision: TurnFileDecision.pending,
          revertible: false,
          binary: true,
          overlapWith: ['turn-0'],
        ),
      ],
      warnings: const ['.env: sensitive path changed'],
    );

Finder fileButton(String path, String label) => find.descendant(
      of: find.ancestor(of: find.text(path), matching: find.byType(Card)),
      matching: find.widgetWithText(TextButton, label),
    );

IconButton sendButton(WidgetTester tester) =>
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_upward));

Map<String, Object?> lastPayload(CapturingSocket socket, String type) =>
    socket.sent.lastWhere((f) => f['type'] == type)['payload']
        as Map<String, Object?>;

void main() {
  testWidgets('the card lists files and sends whole-file actions',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(connected))!;
    controller.state.applyEnvelope(env(snapshotWith([review()])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));

    expect(find.byType(TurnReviewCard), findsOneWidget);
    expect(find.text('Review changes · 2 of 2 left'), findsOneWidget);
    expect(find.text('M'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('overlaps another turn'), findsOneWidget);
    expect(find.text('can only be accepted'), findsOneWidget);
    expect(find.text('binary'), findsOneWidget);
    expect(find.text('.env: sensitive path changed'), findsOneWidget);
    expect(find.byKey(const Key('turn-review-outcome')), findsNothing);
    // Exactly the four decisions: per-file Accept / Reject, Accept all /
    // Reject all. Nothing to finalize.
    expect(find.text('Finalize'), findsNothing);
    expect(find.text('Accept all'), findsOneWidget);
    expect(find.text('Reject all'), findsOneWidget);

    // Not revertible: Reject is disabled, Accept is not.
    expect(
        tester.widget<TextButton>(fileButton('assets/big.bin', 'Reject'))
            .onPressed,
        isNull);
    expect(
        tester.widget<TextButton>(fileButton('assets/big.bin', 'Accept'))
            .onPressed,
        isNotNull);
    await tester.tap(fileButton('src/parser.rs', 'Reject'));
    await tester.pump();
    expect(lastPayload(socket, 'turn_review_action'), {
      'turn_id': 'turn-1',
      'action': 'revert_file',
      'path': 'src/parser.rs',
    });
  });

  testWidgets('accept sends keep_file for that file', (tester) async {
    final (controller, socket) = (await tester.runAsync(connected))!;
    controller.state.applyEnvelope(env(snapshotWith([review()])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));
    await tester.tap(fileButton('assets/big.bin', 'Accept'));
    await tester.pump();
    expect(lastPayload(socket, 'turn_review_action'), {
      'turn_id': 'turn-1',
      'action': 'keep_file',
      'path': 'assets/big.bin',
    });
  });

  testWidgets('a decided file shows its decision instead of buttons',
      (tester) async {
    final (controller, _) = (await tester.runAsync(connected))!;
    const partly = TurnReview(
      turnId: 'turn-1',
      convId: 'c1',
      outcome: TurnOutcome.completed,
      files: [
        TurnReviewFile(
          path: 'src/a.rs',
          change: TurnFileChange.modified,
          decision: TurnFileDecision.revert,
          revertible: true,
          binary: false,
        ),
        TurnReviewFile(
          path: 'src/b.rs',
          change: TurnFileChange.modified,
          decision: TurnFileDecision.pending,
          revertible: true,
          binary: false,
        ),
      ],
    );
    controller.state.applyEnvelope(env(snapshotWith([partly])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));
    expect(find.text('Review changes · 1 of 2 left'), findsOneWidget);
    expect(find.text('rejected'), findsOneWidget);
    expect(fileButton('src/a.rs', 'Accept'), findsNothing);
    expect(fileButton('src/a.rs', 'Reject'), findsNothing);
    expect(fileButton('src/b.rs', 'Accept'), findsOneWidget);
  });

  testWidgets('accept all carries no path; a resolution shows its summary',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(connected))!;
    controller.state.applyEnvelope(env(snapshotWith([review()])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Accept all'));
    await tester.tap(find.widgetWithText(FilledButton, 'Accept all'));
    await tester.pump();
    expect(lastPayload(socket, 'turn_review_action'),
        {'turn_id': 'turn-1', 'action': 'keep_all'});

    controller.state.applyEnvelope(env(const TurnReviewResolved(
      turnId: 'turn-1',
      convId: 'c1',
      kept: 1,
      reverted: 0,
      failed: ['src/parser.rs: edited after the turn'],
    )));
    await tester.pump();
    expect(find.byType(TurnReviewCard), findsNothing);
    expect(find.text('Review done: 1 accepted, 0 rejected, 1 failed'),
        findsOneWidget);
    expect(find.text('• src/parser.rs: edited after the turn'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(find.byKey(const Key('turn-review-resolved')), findsNothing);
  });

  testWidgets('a cancelled turn is highlighted with a revert-all suggestion',
      (tester) async {
    final (controller, _) = (await tester.runAsync(connected))!;
    controller.state.applyEnvelope(
        env(snapshotWith([review(outcome: TurnOutcome.cancelled)])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));
    expect(find.byKey(const Key('turn-review-outcome')), findsOneWidget);
    expect(find.textContaining('This turn was cancelled'), findsOneWidget);
    expect(find.textContaining('Consider Reject all'), findsOneWidget);
  });

  testWidgets('a pending review holds prompts but not slash lines',
      (tester) async {
    final (controller, _) = (await tester.runAsync(connected))!;
    controller.state.applyEnvelope(env(snapshotWith([review()])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));

    expect(find.byKey(const Key('turn-review-send-hint')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'next prompt');
    await tester.pump();
    expect(sendButton(tester).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '/lite');
    await tester.pump();
    expect(sendButton(tester).onPressed, isNotNull);

    // Resolved: the hint goes and prompts are sendable again.
    controller.state.applyEnvelope(env(
        const TurnReviewResolved(turnId: 'turn-1', kept: 2, reverted: 0)));
    await tester.enterText(find.byType(TextField), 'next prompt');
    await tester.pump();
    expect(find.byKey(const Key('turn-review-send-hint')), findsNothing);
    expect(sendButton(tester).onPressed, isNotNull);
  });

  testWidgets('without the turn_review capability nothing is shown',
      (tester) async {
    final (controller, _) =
        (await tester.runAsync(() => connected(capabilities: const [])))!;
    controller.state.applyEnvelope(env(snapshotWith([review()])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));
    expect(find.byType(TurnReviewCard), findsNothing);
    expect(find.byKey(const Key('turn-review-send-hint')), findsNothing);
    await tester.enterText(find.byType(TextField), 'next prompt');
    await tester.pump();
    expect(sendButton(tester).onPressed, isNotNull);
  });

  testWidgets('unknown_turn_review is a calm race that resyncs',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(connected))!;
    controller.state.applyEnvelope(env(snapshotWith([review()])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));

    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Accept all'));
    await tester.tap(find.widgetWithText(FilledButton, 'Accept all'));
    await tester.pump();
    final command = socket.sent.lastWhere(
        (f) => f['type'] == 'turn_review_action');
    expect(command['payload'], {'turn_id': 'turn-1', 'action': 'keep_all'});

    await tester.runAsync(() async {
      socket.serverSend(serverFrame('command_error', {
        'command_id': command['command_id'],
        'code': 'unknown_turn_review',
        'message': 'no pending review turn-1',
      }));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.text('That review was already finalized — showing the '
        'current state.'), findsOneWidget);
    expect(socket.sent.last['type'], 'request_snapshot');
  });

  testWidgets('a review for a conversation the phone does not have gets a '
      'badge and its own screen', (tester) async {
    final (controller, socket) = (await tester.runAsync(connected))!;
    const orphan = TurnReview(
      turnId: 'turn-9',
      convId: 'closed-on-desktop',
      outcome: TurnOutcome.completed,
      files: [
        TurnReviewFile(
          path: 'src/lost.rs',
          change: TurnFileChange.modified,
          decision: TurnFileDecision.pending,
          revertible: true,
          binary: false,
        ),
      ],
    );
    controller.state.applyEnvelope(env(snapshotWith([orphan])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));

    // Not on the viewed conversation's screen, but not lost either.
    expect(find.byType(TurnReviewCard), findsNothing);
    expect(find.byKey(const Key('orphan-turn-reviews')), findsOneWidget);
    await tester.tap(find.byKey(const Key('orphan-turn-reviews')));
    await tester.pumpAndSettle();
    expect(find.byType(OrphanTurnReviewsScreen), findsOneWidget);
    expect(find.text('Conversation closed-on-desktop (not open)'), findsOneWidget);
    expect(find.text('src/lost.rs'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Accept all'));
    await tester.pump();
    expect(lastPayload(socket, 'turn_review_action'),
        {'turn_id': 'turn-9', 'action': 'keep_all'});

    controller.state.applyEnvelope(env(const TurnReviewResolved(
        turnId: 'turn-9', convId: 'closed-on-desktop', kept: 1, reverted: 0)));
    await tester.pump();
    expect(find.text('No pending turn reviews'), findsOneWidget);
  });

  testWidgets('a decision this client does not know reads as decided on the '
      'desktop', (tester) async {
    final (controller, _) = (await tester.runAsync(connected))!;
    const fromNewerServer = TurnReview(
      turnId: 'turn-1',
      convId: 'c1',
      outcome: TurnOutcome.unknown,
      files: [
        TurnReviewFile(
          path: 'src/parser.rs',
          change: TurnFileChange.unknown,
          decision: TurnFileDecision.unknown,
          revertible: true,
          binary: false,
        ),
      ],
    );
    controller.state.applyEnvelope(env(snapshotWith([fromNewerServer])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));

    expect(find.text('decided on desktop'), findsOneWidget);
    expect(find.text('?'), findsOneWidget);
    // Unknown outcome: shown neutrally, no reject-all nudge.
    expect(find.byKey(const Key('turn-review-outcome')), findsNothing);
    // A decision is final: no per-file buttons for it.
    expect(fileButton('src/parser.rs', 'Accept'), findsNothing);
    expect(fileButton('src/parser.rs', 'Reject'), findsNothing);
  });

  testWidgets('/reset during a pending review warns that the review stays',
      (tester) async {
    final (controller, _) = (await tester.runAsync(() => connected(
          confirmRequired: const ['/reset'],
          allowedSlash: const ['/reset'],
        )))!;
    controller.state.applyEnvelope(env(snapshotWith([review()])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));

    await tester.enterText(find.byType(TextField), '/reset');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(find.textContaining('The pending turn review stays open'),
        findsOneWidget);
  });

  testWidgets('a turn_review_pending refusal maps to a friendly message',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(connected))!;
    // No review known locally (e.g. a frame not yet received): the server
    // refuses the prompt and the user is told why.
    controller.state.applyEnvelope(env(snapshotWith(const [])));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(controller: controller)));
    await tester.enterText(find.byType(TextField), 'next prompt');
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_upward));
    await tester.pump();
    final command = socket.sent.lastWhere((f) => f['type'] == 'send_prompt');
    await tester.runAsync(() async {
      socket.serverSend(serverFrame('command_error', {
        'command_id': command['command_id'],
        'code': 'turn_review_pending',
        'message': 'review pending',
      }));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(
        find.text('Review the files the last turn changed before sending the '
            'next prompt.'),
        findsOneWidget);
  });
}
