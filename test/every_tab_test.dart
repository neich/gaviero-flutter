/// D4: viewed vs active, newest-page replace, unread, targeting, 1.0 fallback.
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
import 'package:gaviero_remote/src/ui/permission_card.dart';

ServerEnvelope env(ServerPayload payload, {int seq = 1}) => ServerEnvelope(
      version: protocolVersion,
      instanceId: 'inst-1',
      seq: seq,
      revision: 1,
      payload: payload,
    );

ConversationSummary summary(String id,
        {int revision = 1, String title = 'Chat', bool streaming = false}) =>
    ConversationSummary(
      convId: id,
      convRevision: revision,
      title: title,
      isStreaming: streaming,
      autoApprove: false,
    );

Message msg(int seq, String content, {Role role = Role.user}) => Message(
      seq: seq,
      role: role,
      content: content,
      truncated: false,
      toolCalls: const [],
      codeBlocks: const [],
    );

Snapshot snapshot({
  List<ConversationSummary>? conversations,
  String activeId = 'c1',
  List<Message>? messages,
  int oldestSeq = 10,
  bool hasOlder = true,
}) {
  final convs = conversations ?? [summary('c1'), summary('c2')];
  return Snapshot(
    revision: 1,
    conversations: convs,
    activeId: activeId,
    activeConversation: ConversationState(
      summary: convs.firstWhere((c) => c.convId == activeId),
      messages: messages ??
          [msg(10, 'hello'), msg(11, 'hi', role: Role.assistant)],
      oldestSeq: oldestSeq,
      hasOlderMessages: hasOlder,
    ),
    openPermissions: const [],
    openProposals: const [],
    settings: const RemoteSettings(),
  );
}

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

Future<(RemoteController, CapturingSocket)> connected({
  List<String> capabilities = const [],
}) async {
  _seq = 1;
  final socket = CapturingSocket();
  final controller = RemoteController(
    connection: RemoteConnection(connector: (url, token) async => socket),
    state: AppState(),
  );
  await controller.connection.start(Uri.parse('wss://h/v1/ws'), 't');
  socket.serverSend({
    'version': {'major': 1, 'minor': capabilities.isEmpty ? 0 : 1},
    'instance_id': 'i1',
    'seq': _seq++,
    'revision': 1,
    'type': 'hello',
    'payload': {
      'protocol_version': {
        'major': 1,
        'minor': capabilities.isEmpty ? 0 : 1,
      },
      'instance_id': 'i1',
      'tui_version': '0.1.0',
      'workspace': {'id': 'w', 'display_name': 'w'},
      'capabilities': capabilities,
      'confirm_required': <String>[],
      'allowed_slash_commands': <String>['/lite'],
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
  test('a snapshot keeps a loaded non-active transcript and marks it stale',
      () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    state.expectNewestPage('c2');
    state.applyEnvelope(env(MessagePage(
      convId: 'c2',
      messages: [msg(1, 'kept')],
      oldestSeq: 1,
      hasOlderMessages: false,
    )));
    expect(state.conversation('c2')!.transcriptLoaded, isTrue);
    state.applyEnvelope(env(snapshot(), seq: 2));
    expect(state.conversation('c2')!.messages.single.content, 'kept');
    expect(state.conversation('c2')!.transcriptStale, isTrue);
    expect(state.conversation('c1')!.transcriptLoaded, isTrue);
    expect(state.conversation('c1')!.transcriptStale, isFalse);
  });

  test('viewing a stale transcript asks for exactly one newest page, '
      'and the reply replaces it', () {
    final state = AppState();
    final asked = <String>[];
    state.onNeedNewestPage = asked.add;
    state.applyEnvelope(env(snapshot()));
    state.expectNewestPage('c2');
    state.applyEnvelope(env(MessagePage(
      convId: 'c2',
      messages: [msg(1, 'old')],
      oldestSeq: 1,
      hasOlderMessages: false,
    )));
    state.applyEnvelope(env(snapshot(), seq: 2));
    asked.clear();
    state.view('c2');
    expect(asked, ['c2']);
    state.expectNewestPage('c2');
    state.applyEnvelope(env(MessagePage(
      convId: 'c2',
      messages: [msg(50, 'reset-tail')],
      oldestSeq: 50,
      hasOlderMessages: true,
    )));
    expect(state.conversation('c2')!.messages.single.content, 'reset-tail');
    expect(state.conversation('c2')!.transcriptStale, isFalse);
    asked.clear();
    state.view('c2');
    expect(asked, isEmpty);
  });

  test('message_complete on a non-viewed tab increments unread and does '
      'not mark the transcript loaded', () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    expect(state.viewedId, 'c1');
    state.applyEnvelope(env(MessageComplete(
      convId: 'c2',
      message: msg(99, 'live', role: Role.assistant),
    )));
    final c2 = state.conversation('c2')!;
    expect(c2.unread, 1);
    expect(c2.transcriptLoaded, isFalse);
    expect(c2.oldestSeq, isNull);
    expect(c2.messages.single.seq, 99);
    state.view('c2');
    expect(state.conversation('c2')!.unread, 0);
  });

  test('enabling follow-desktop snaps viewedId to active_id on the next '
      'conversation_state_changed', () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    expect(state.viewedId, 'c1');
    state.setFollowDesktop(true);
    expect(state.viewedId, 'c1');
    state.applyEnvelope(env(ConversationStateChanged(
        conversation: summary('c2'), activeId: 'c2')));
    expect(state.viewedId, 'c2');
  });

  test('permission card surface is the viewed tab; badge counts the rest',
      () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    const viewed = PermissionRequest(
      convId: 'c1',
      requestId: 'r1',
      toolName: 'Bash',
      description: 'ls',
      input: {},
    );
    const other = PermissionRequest(
      convId: 'c2',
      requestId: 'r2',
      toolName: 'Bash',
      description: 'pwd',
      input: {},
    );
    state.applyEnvelope(env(const PermissionRequestFrame(viewed)));
    state.applyEnvelope(env(const PermissionRequestFrame(other)));
    expect(state.viewedPermissions.single.requestId, 'r1');
    expect(state.otherPermissionCount, 1);
    expect(state.oldestOtherPermission!.requestId, 'r2');
  });

  test('sendPrompt targets viewedId while active_id differs', () async {
    final (controller, socket) = await connected();
    controller.state.applyEnvelope(env(snapshot()));
    controller.state.view('c2');
    controller.sendPrompt('from the phone');
    await Future<void>.delayed(Duration.zero);
    final frame = socket.sent.lastWhere((f) => f['type'] == 'send_prompt');
    expect((frame['payload'] as Map)['conv_id'], 'c2');
    expect(controller.state.activeId, 'c1');
    await controller.connection.stop();
  });

  test('a 1.0 hello newest-page request carries before_seq 2^53-1', () async {
    final (controller, socket) = await connected();
    controller.state.applyEnvelope(env(snapshot()));
    controller.requestNewestPage('c2');
    await Future<void>.delayed(Duration.zero);
    final frame =
        socket.sent.lastWhere((f) => f['type'] == 'request_messages');
    expect((frame['payload'] as Map)['before_seq'], legacyNewestPageBeforeSeq);
    expect((frame['payload'] as Map)['conv_id'], 'c2');
    await controller.connection.stop();
  });

  test('a 1.1 hello newest-page request omits before_seq', () async {
    final (controller, socket) =
        await connected(capabilities: [Capability.latestPage]);
    controller.state.applyEnvelope(env(snapshot()));
    controller.requestNewestPage('c2');
    await Future<void>.delayed(Duration.zero);
    final frame =
        socket.sent.lastWhere((f) => f['type'] == 'request_messages');
    expect((frame['payload'] as Map).containsKey('before_seq'), isFalse);
    await controller.connection.stop();
  });

  testWidgets('tab strip lists every conversation; permission card is viewed-only',
      (tester) async {
    final state = AppState();
    state.applyEnvelope(env(snapshot(
      conversations: [
        summary('c1', title: 'Alpha'),
        summary('c2', title: 'Beta'),
      ],
    )));
    const other = PermissionRequest(
      convId: 'c2',
      requestId: 'r-other',
      toolName: 'Bash',
      description: 'pwd',
      input: {},
    );
    state.applyEnvelope(env(const PermissionRequestFrame(other)));
    final controller = RemoteController(state: state);
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(controller: controller),
    ));
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.byType(PermissionCard), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'Beta'));
    await tester.pump();
    expect(controller.state.viewedId, 'c2');
    expect(find.byType(PermissionCard), findsOneWidget);
  });
}
