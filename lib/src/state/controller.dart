/// One instance's session: its connection, its mirror state, and the
/// high-level actions the screens call. [RemoteHub] owns one per recently
/// used instance, so leaving an instance and coming back finds the same
/// conversations, drafts and section state. Freshness tokens (§3.5) are
/// attached here: `conv_revision` on rename/reset, `proposal_revision` on
/// review actions, `request_id` on permission decisions.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/protocol.dart';
import '../services/instance_store.dart';
import '../transport/connection.dart';
import 'app_state.dart';

final class RemoteController extends ChangeNotifier {
  final RemoteConnection connection;
  final AppState state;

  /// Bumped when a conversation is opened from outside the chat UI (a
  /// notification tap, a deep link): the home screen switches to its
  /// Conversations section.
  final ValueNotifier<int> conversationFocus = ValueNotifier(0);

  /// Every `hello`, before the state sees it: the hub records the
  /// workspace id and name it carries.
  void Function(Hello hello)? onHello;

  InstanceRecord? _current;
  bool _disposed = false;
  final Set<String> _pagesInFlight = {};
  final Set<String> _newestInFlight = {};

  RemoteController({
    RemoteConnection? connection,
    AppState? state,
    InstanceRecord? instance,
  }) : connection = connection ?? RemoteConnection(),
       state = state ?? AppState(),
       _current = instance {
    this.connection.onEnvelope = _onEnvelope;
    this.connection.onInstanceChanged = this.state.clear;
    this.state.onNeedNewestPage = (convId) {
      requestNewestPage(convId);
    };
    this.connection.addListener(notifyListeners);
    this.state.addListener(notifyListeners);
  }

  /// The instance this session belongs to (null in screen tests).
  InstanceRecord? get current => _current;

  /// The hub learned newer details (a `hello`, a directory refresh).
  void updateInstance(InstanceRecord instance) {
    _current = instance;
    notifyListeners();
  }

  void _onEnvelope(ServerEnvelope envelope) {
    if (envelope.payload case final Hello hello) {
      onHello?.call(hello);
    }
    state.applyEnvelope(envelope);
  }

  // -- actions ------------------------------------------------------------

  Future<CommandOutcome> sendPrompt(String text) {
    final convId = state.viewedId;
    if (convId == null) return Future.value(const CommandDropped());
    return connection.send(SendPrompt(convId: convId, text: text));
  }

  Future<CommandOutcome> sendSlash(String line, {required bool confirmed}) {
    final convId = state.viewedId;
    if (convId == null) return Future.value(const CommandDropped());
    return connection.send(
      Slash(convId: convId, line: line, confirmed: confirmed),
    );
  }

  Future<CommandOutcome> interrupt() {
    final conv = state.viewed;
    if (conv == null) return Future.value(const CommandDropped());
    return connection.send(
      Interrupt(
        convId: conv.summary.convId,
        turnId: conv.summary.pendingTurnId,
      ),
    );
  }

  Future<CommandOutcome> newConversation() =>
      connection.send(const NewConversation());

  Future<CommandOutcome> switchConversation(String convId) =>
      connection.send(SwitchConversation(convId: convId));

  Future<CommandOutcome> renameConversation(String convId, String title) {
    final conv = state.conversation(convId);
    if (conv == null) return Future.value(const CommandDropped());
    return connection.send(
      RenameConversation(
        convId: convId,
        convRevision: conv.summary.convRevision,
        title: title,
      ),
    );
  }

  Future<CommandOutcome> resetConversation(String convId) {
    final conv = state.conversation(convId);
    if (conv == null) return Future.value(const CommandDropped());
    return connection.send(
      ResetConversation(
        convId: convId,
        convRevision: conv.summary.convRevision,
      ),
    );
  }

  /// Scroll-back paging (§3.6): one cursor concept, `before_seq =
  /// oldest_seq`, deduped while a page is in flight.
  Future<void> requestOlderMessages(String convId, {int limit = 50}) async {
    final conv = state.conversation(convId);
    final cursor = conv?.oldestSeq;
    if (conv == null || cursor == null || !conv.hasOlderMessages) return;
    if (!_pagesInFlight.add(convId)) return;
    try {
      await connection.send(
        RequestMessages(convId: convId, beforeSeq: cursor, limit: limit),
      );
    } finally {
      _pagesInFlight.remove(convId);
    }
  }

  Future<void> requestNewestPage(String convId, {int limit = 50}) async {
    if (!_newestInFlight.add(convId)) return;
    state.expectNewestPage(convId);
    try {
      final supportsLatest = connection.hello?.supportsLatestPage ?? false;
      await connection.send(
        RequestMessages(
          convId: convId,
          beforeSeq: supportsLatest ? null : legacyNewestPageBeforeSeq,
          limit: limit,
        ),
      );
    } finally {
      _newestInFlight.remove(convId);
    }
  }

  Future<CommandOutcome> permissionDecision(
    String requestId, {
    required bool allow,
    List<List<int>>? answers,
    String? message,
    PermissionGrant? grant,
  }) => connection.send(
    PermissionDecision(
      requestId: requestId,
      allow: allow,
      answers: answers,
      message: message,
      grant: grant,
    ),
  );

  /// The server advertises [Capability.permissionTurnGrant]: an allow may
  /// carry `grant: mcp_server_turn` for a request with `mcp_server`.
  bool get supportsPermissionTurnGrant =>
      connection.hello?.hasCapability(Capability.permissionTurnGrant) ?? false;

  /// The server advertises [Capability.permissionGrants]: every request lists
  /// the grants it accepts in `PermissionRequest.grants`, and the card offers
  /// exactly those (the desktop's a / A / p answers).
  bool get supportsPermissionGrants =>
      connection.hello?.hasCapability(Capability.permissionGrants) ?? false;

  Future<CommandOutcome> reviewAction(
    int proposalId,
    ReviewActionKind action, {
    int? hunkIndex,
  }) {
    final proposal = state.proposal(proposalId);
    if (proposal == null) return Future.value(const CommandDropped());
    return connection.send(
      ReviewAction(
        proposalId: proposalId,
        proposalRevision: proposal.revision,
        action: action,
        hunkIndex: hunkIndex,
      ),
    );
  }

  Future<CommandOutcome> requestProposal(int proposalId) =>
      connection.send(RequestProposal(proposalId: proposalId));

  /// The server advertised [Capability.turnReview]: turn-review frames may
  /// arrive and `turn_review_action` is accepted.
  bool get supportsTurnReview =>
      connection.hello?.hasCapability(Capability.turnReview) ?? false;

  /// Whole-file turn-review decisions (per-hunk is desktop-only). Dropped
  /// without sending on a server lacking [Capability.turnReview]. An
  /// `unknown_turn_review` reply means the review was finalized elsewhere
  /// (usually the desktop) — a benign race; resync so a missed
  /// `turn_review_resolved` cannot leave the conversation looking blocked.
  Future<CommandOutcome> turnReviewAction(
    String turnId,
    TurnReviewActionKind action, {
    String? path,
    String? folder,
  }) async {
    if (!supportsTurnReview) return const CommandDropped();
    final outcome = await connection.send(
      TurnReviewAction(
        turnId: turnId,
        action: action,
        path: path,
        folder: folder,
      ),
    );
    if (outcome case CommandFail(:final error)
        when error.code == ErrorCode.unknownTurnReview) {
      unawaited(connection.send(const RequestSnapshot()));
    }
    return outcome;
  }

  /// Workspace paths for an `@` reference; dropped without sending on a
  /// server lacking [Capability.fileCompletions].
  Future<CommandOutcome> requestFileCompletions(String query) {
    if (!(connection.hello?.hasCapability(Capability.fileCompletions) ??
        false)) {
      return Future.value(const CommandDropped());
    }
    return connection.send(RequestFileCompletions(query: query));
  }

  /// Catalog skills for a `$skill` invocation; dropped without sending on a
  /// server lacking [Capability.skillCompletions].
  Future<CommandOutcome> requestSkillCompletions(String query) {
    if (!(connection.hello?.hasCapability(Capability.skillCompletions) ??
        false)) {
      return Future.value(const CommandDropped());
    }
    return connection.send(RequestSkillCompletions(query: query));
  }

  /// The server advertises [Capability.fileBrowser]: the explorer may send
  /// `list_directory` / `read_file`.
  bool get supportsFileBrowser =>
      connection.hello?.hasCapability(Capability.fileBrowser) ?? false;

  /// One directory of the workspace; `path == null` lists the roots.
  Future<CommandOutcome> requestDirectory(String? path) {
    if (!supportsFileBrowser) return Future.value(const CommandDropped());
    return connection.send(ListDirectory(path: path));
  }

  /// One regular file, read-only. Dropped without sending on older servers.
  Future<CommandOutcome> requestFile(String path) {
    if (!supportsFileBrowser) return Future.value(const CommandDropped());
    return connection.send(ReadFile(path: path));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    connection.removeListener(notifyListeners);
    state.removeListener(notifyListeners);
    conversationFocus.dispose();
    connection.dispose();
    state.dispose();
    super.dispose();
  }
}
