/// State-layer verification (B4/B5 machine-verifiable parts): idempotent
/// snapshot application, `conversation_state_changed` upserts,
/// `conversation_removed`, streaming accumulation, page merging without
/// duplicates or gaps, and permission/proposal lifecycles.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/protocol.dart';
import 'package:gaviero_remote/src/state/app_state.dart';

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
  List<PermissionRequest> permissions = const [],
  List<ProposalSummary> proposals = const [],
}) {
  final convs = conversations ?? [summary('c1'), summary('c2')];
  return Snapshot(
    revision: 1,
    conversations: convs,
    activeId: activeId,
    activeConversation: ConversationState(
      summary: convs.firstWhere((c) => c.convId == activeId),
      messages: messages ?? [msg(10, 'hello'), msg(11, 'hi', role: Role.assistant)],
      oldestSeq: oldestSeq,
      hasOlderMessages: hasOlder,
    ),
    openPermissions: permissions,
    openProposals: proposals,
    settings: const RemoteSettings(),
  );
}

void main() {
  test('applying the same snapshot twice is idempotent', () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    state.applyEnvelope(env(snapshot(), seq: 2));
    expect(state.conversations, hasLength(2));
    expect(state.activeId, 'c1');
    expect(state.active!.messages.map((m) => m.seq), [10, 11]);
    expect(state.active!.hasOlderMessages, isTrue);
  });

  test('conversation_state_changed upserts without a snapshot', () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    // Known conversation: update in place.
    state.applyEnvelope(env(ConversationStateChanged(
        conversation: summary('c1', revision: 2, title: 'Renamed'),
        activeId: 'c1')));
    expect(state.conversation('c1')!.summary.title, 'Renamed');
    expect(state.conversation('c1')!.summary.convRevision, 2);
    expect(state.conversation('c1')!.messages, isNotEmpty,
        reason: 'an upsert must not drop the cached transcript');
    // Unknown conversation: insert.
    state.applyEnvelope(env(ConversationStateChanged(
        conversation: summary('c9', title: 'New tab'), activeId: 'c1')));
    expect(state.conversation('c9'), isNotNull);
  });

  test('switching to a conversation without a transcript asks for a '
      'snapshot', () {
    final state = AppState();
    var asked = 0;
    state.onNeedSnapshot = () => asked++;
    state.applyEnvelope(env(snapshot()));
    expect(asked, 0, reason: 'active conv transcript came in the snapshot');
    state.applyEnvelope(env(ConversationStateChanged(
        conversation: summary('c2'), activeId: 'c2')));
    expect(asked, 1);
  });

  test('conversation_removed drops the tab and follows active_id', () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    state.applyEnvelope(
        env(const ConversationRemoved(convId: 'c2', activeId: 'c1')));
    expect(state.conversation('c2'), isNull);
    expect(state.activeId, 'c1');
  });

  test('stream chunks accumulate; a new turn resets; message_complete '
      'clears the buffer without duplicating', () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    state.applyEnvelope(env(
        const StreamChunk(convId: 'c1', turnId: 't1', text: 'Hel')));
    state.applyEnvelope(env(
        const StreamChunk(convId: 'c1', turnId: 't1', text: 'lo')));
    expect(state.active!.streamingText, 'Hello');

    state.applyEnvelope(env(
        const StreamChunk(convId: 'c1', turnId: 't2', text: 'Fresh')));
    expect(state.active!.streamingText, 'Fresh',
        reason: 'a new turn_id resets the buffer');

    state.applyEnvelope(env(MessageComplete(
        convId: 'c1', message: msg(12, 'Fresh!', role: Role.assistant))));
    expect(state.active!.streamingText, isEmpty);
    expect(state.active!.messages.last.content, 'Fresh!');
    // Idempotency: the same message_complete again must not duplicate.
    state.applyEnvelope(env(MessageComplete(
        convId: 'c1', message: msg(12, 'Fresh!', role: Role.assistant))));
    expect(state.active!.messages.where((m) => m.seq == 12), hasLength(1));
  });

  test('a cancelled turn drops its partial text', () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    state.applyEnvelope(env(
        const StreamChunk(convId: 'c1', turnId: 't1', text: 'partial')));
    state.applyEnvelope(env(const StreamingEnded(
        convId: 'c1', turnId: 't1', cancelled: true, proposalCount: 0)));
    expect(state.active!.streamingText, isEmpty);
  });

  test('message pages merge without duplicates, gaps, or jumps', () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    state.applyEnvelope(env(MessagePage(
      convId: 'c1',
      messages: [msg(7, 'seven'), msg(8, 'eight'), msg(9, 'nine')],
      oldestSeq: 7,
      hasOlderMessages: true,
    )));
    expect(state.active!.messages.map((m) => m.seq), [7, 8, 9, 10, 11]);
    expect(state.active!.oldestSeq, 7);
    // The same page again: no duplicates.
    state.applyEnvelope(env(MessagePage(
      convId: 'c1',
      messages: [msg(7, 'seven'), msg(8, 'eight'), msg(9, 'nine')],
      oldestSeq: 7,
      hasOlderMessages: false,
    )));
    expect(state.active!.messages.map((m) => m.seq), [7, 8, 9, 10, 11]);
    expect(state.active!.hasOlderMessages, isFalse);
  });

  test('permission request/closed lifecycle, with notification hook', () {
    final state = AppState();
    final notified = <String>[];
    state.onPermissionRequested = (r) => notified.add(r.requestId);
    state.applyEnvelope(env(snapshot()));
    const request = PermissionRequest(
      convId: 'c1',
      requestId: 'req-1',
      toolName: 'Bash',
      description: 'Run: ls',
      input: {'command': 'ls'},
    );
    state.applyEnvelope(env(const PermissionRequestFrame(request)));
    expect(state.openPermissions, hasLength(1));
    expect(notified, ['req-1']);
    // Same request re-broadcast: no second notification.
    state.applyEnvelope(env(const PermissionRequestFrame(request)));
    expect(notified, ['req-1']);
    // Desktop answered first: dismiss without error.
    state.applyEnvelope(env(const PermissionClosed(
      convId: 'c1',
      requestId: 'req-1',
      outcome: PermissionOutcome.allowed,
      answeredBy: AnsweredBy.desktop,
    )));
    expect(state.openPermissions, isEmpty);
  });

  test('proposal lifecycle: snapshot summary, detail upsert, finalize', () {
    final state = AppState();
    final proposalSummary = ProposalSummary(
      proposalId: 42,
      proposalRevision: 1,
      source: 'agent',
      path: 'src/a.rs',
      status: ProposalStatus.pending,
      isDeletion: false,
      conflictsWith: const [],
      hunkCount: 1,
      addedLines: 2,
      removedLines: 0,
      hunks: const [
        HunkSummary(
            index: 0,
            hunkType: HunkType.added,
            description: 'fn new',
            status: HunkStatus.pending)
      ],
    );
    state.applyEnvelope(env(snapshot(proposals: [proposalSummary])));
    expect(state.openProposals.single.id, 42);
    expect(state.proposal(42)!.detail, isNull);

    final detail = Proposal(
      proposalId: 42,
      proposalRevision: 2,
      source: 'agent',
      path: 'src/a.rs',
      status: ProposalStatus.pending,
      isDeletion: false,
      conflictsWith: const [],
      hunks: const [],
    );
    state.applyEnvelope(env(
        ProposalEvent(lifecycle: ProposalLifecycle.detail, proposal: detail)));
    expect(state.proposal(42)!.revision, 2);

    state.applyEnvelope(env(const ProposalFinalized(
        proposalId: 42, path: 'src/a.rs', outcome: ProposalOutcome.accepted)));
    expect(state.openProposals, isEmpty);
  });

  test('token usage and cost accumulate per conversation', () {
    final state = AppState();
    state.applyEnvelope(env(snapshot()));
    state.applyEnvelope(env(const CostUpdate(
        convId: 'c1', turnId: 't1', usd: 0.02)));
    state.applyEnvelope(env(const CostUpdate(
        convId: 'c1', turnId: 't2', usd: 0.03)));
    expect(state.active!.lastTurnCostUsd, 0.03);
    expect(state.active!.sessionCostUsd, closeTo(0.05, 1e-9));
  });
}
