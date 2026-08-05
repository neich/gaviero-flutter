/// Mirror-side state, driven exclusively by server envelopes (§3.4 of
/// PLAN.md): `snapshot` replaces wholesale, `conversation_state_changed` /
/// `conversation_removed` upsert/remove, and both must be idempotent —
/// the same snapshot may be applied twice, and a state-change may arrive
/// for a conversation already known.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../protocol/protocol.dart';

final class ConversationData {
  ConversationSummary summary;

  /// Sorted ascending by `Message.seq`.
  List<Message> messages;

  /// Paging cursor (§3.6): next `request_messages.before_seq`. Null until a
  /// snapshot or page has arrived for this conversation.
  int? oldestSeq;
  bool hasOlderMessages;

  /// In-progress turn (coalesced `stream_chunk` text).
  String streamingText = '';
  String? streamingTurnId;
  String? streamingStatus;
  List<String> liveToolCalls = [];

  TokenUsage? lastUsage;
  double? lastTurnCostUsd;
  double sessionCostUsd = 0;

  ConversationData(this.summary)
      : messages = [],
        hasOlderMessages = false;

  bool get hasTranscript => oldestSeq != null;
}

final class ProposalData {
  ProposalSummary? summary;
  Proposal? detail;

  ProposalData({this.summary, this.detail});

  int get id => detail?.proposalId ?? summary!.proposalId;
  int get revision => detail?.proposalRevision ?? summary!.proposalRevision;
  String get path => detail?.path ?? summary!.path;
  ProposalStatus get status => detail?.status ?? summary!.status;
  bool get isDeletion => detail?.isDeletion ?? summary!.isDeletion;
  String? get convId => detail?.convId ?? summary?.convId;
}

final class AppState extends ChangeNotifier {
  final LinkedHashMap<String, ConversationData> _conversations =
      LinkedHashMap();
  String? _activeId;
  final LinkedHashMap<String, PermissionRequest> _permissions =
      LinkedHashMap();
  final LinkedHashMap<int, ProposalData> _proposals = LinkedHashMap();
  RemoteSettings _settings = const RemoteSettings();

  /// The active conversation changed (or arrived) without a cached
  /// transcript — the owner should send `request_snapshot`.
  VoidCallback? onNeedSnapshot;

  /// Hooks for local notifications (B10).
  void Function(PermissionRequest request)? onPermissionRequested;
  void Function(StreamingEnded ended)? onStreamingEnded;

  /// One-shot signal for the review UI: a `proposal_updated` arrived.
  void Function(Proposal proposal)? onProposalUpdated;

  List<ConversationData> get conversations =>
      List.unmodifiable(_conversations.values);
  String? get activeId => _activeId;
  ConversationData? get active =>
      _activeId == null ? null : _conversations[_activeId];
  ConversationData? conversation(String convId) => _conversations[convId];
  List<PermissionRequest> get openPermissions =>
      List.unmodifiable(_permissions.values);
  List<ProposalData> get openProposals =>
      List.unmodifiable(_proposals.values);
  ProposalData? proposal(int id) => _proposals[id];
  RemoteSettings get settings => _settings;

  /// The TUI restarted — drop everything; a fresh snapshot is coming.
  void clear() {
    _conversations.clear();
    _activeId = null;
    _permissions.clear();
    _proposals.clear();
    notifyListeners();
  }

  void applyEnvelope(ServerEnvelope envelope) {
    switch (envelope.payload) {
      case Hello():
        break; // Connection-level; nothing to mirror.
      case final Snapshot snapshot:
        _applySnapshot(snapshot);
      case final ConversationStateChanged change:
        _upsertSummary(change.conversation);
        _setActive(change.activeId);
      case final ConversationRemoved removed:
        _conversations.remove(removed.convId);
        _setActive(removed.activeId);
      case final MessagePage page:
        _applyMessagePage(page);
      case final StreamChunk chunk:
        final conv = _conversations[chunk.convId];
        if (conv == null) break;
        if (conv.streamingTurnId != chunk.turnId) {
          conv.streamingTurnId = chunk.turnId;
          conv.streamingText = '';
          conv.liveToolCalls = [];
        }
        conv.streamingText += chunk.text;
      case final StreamingStatus status:
        final conv = _conversations[status.convId];
        if (conv == null) break;
        conv.streamingTurnId ??= status.turnId;
        conv.streamingStatus = status.status;
      case final StreamingEnded ended:
        final conv = _conversations[ended.convId];
        if (conv != null) {
          conv.streamingStatus = null;
          conv.liveToolCalls = [];
          // A cancelled turn's partial text never becomes a message; drop it
          // rather than displaying an orphan the desktop does not have.
          if (ended.cancelled) {
            conv.streamingText = '';
            conv.streamingTurnId = null;
          }
        }
        onStreamingEnded?.call(ended);
      case final ToolCallStarted tool:
        final conv = _conversations[tool.convId];
        if (conv == null) break;
        if (conv.streamingTurnId != tool.turnId) {
          conv.streamingTurnId = tool.turnId;
          conv.streamingText = '';
          conv.liveToolCalls = [];
        }
        conv.liveToolCalls = [...conv.liveToolCalls, tool.toolName];
      case final MessageComplete complete:
        final conv = _conversations[complete.convId];
        if (conv == null) break;
        _insertMessage(conv, complete.message);
        if (complete.message.role == Role.assistant) {
          conv.streamingText = '';
          conv.streamingTurnId = null;
        }
      case final PermissionRequestFrame frame:
        final isNew = !_permissions.containsKey(frame.request.requestId);
        _permissions[frame.request.requestId] = frame.request;
        if (isNew) onPermissionRequested?.call(frame.request);
      case final PermissionClosed closed:
        _permissions.remove(closed.requestId);
      case final ProposalEvent event:
        final existing = _proposals[event.proposal.proposalId];
        if (existing == null) {
          _proposals[event.proposal.proposalId] =
              ProposalData(detail: event.proposal);
        } else {
          existing.detail = event.proposal;
        }
        if (event.lifecycle == ProposalLifecycle.updated) {
          onProposalUpdated?.call(event.proposal);
        }
      case final ProposalFinalized finalized:
        _proposals.remove(finalized.proposalId);
      case final TokenUsageEvent usage:
        final conv = _conversations[usage.convId];
        if (conv == null) break;
        conv.lastUsage = usage.usage;
      case final CostUpdate cost:
        final conv = _conversations[cost.convId];
        if (conv == null) break;
        conv.lastTurnCostUsd = cost.usd;
        conv.sessionCostUsd += cost.usd;
      case CommandResult() || CommandError():
        break; // Correlated by the connection layer's command futures.
      case UnknownServerPayload():
        break; // Forward compat: ignore.
    }
    notifyListeners();
  }

  void _applySnapshot(Snapshot snapshot) {
    // Replace local state wholesale (§3.4). Transcripts of non-active
    // conversations are dropped — a snapshot means "you may have missed
    // frames", and stale transcripts are worse than a re-page.
    final fresh = <String, ConversationData>{};
    for (final summary in snapshot.conversations) {
      fresh[summary.convId] = ConversationData(summary);
    }
    final activeState = snapshot.activeConversation;
    final activeData = fresh[activeState.summary.convId];
    if (activeData != null) {
      activeData.summary = activeState.summary;
      activeData.messages = [...activeState.messages]
        ..sort((a, b) => a.seq.compareTo(b.seq));
      activeData.oldestSeq = activeState.oldestSeq;
      activeData.hasOlderMessages = activeState.hasOlderMessages;
    }
    _conversations
      ..clear()
      ..addAll(fresh);
    _activeId = snapshot.activeId;
    _permissions.clear();
    for (final request in snapshot.openPermissions) {
      _permissions[request.requestId] = request;
    }
    _proposals.clear();
    for (final summary in snapshot.openProposals) {
      _proposals[summary.proposalId] = ProposalData(summary: summary);
    }
    _settings = snapshot.settings;
  }

  void _upsertSummary(ConversationSummary summary) {
    final existing = _conversations[summary.convId];
    if (existing == null) {
      _conversations[summary.convId] = ConversationData(summary);
    } else {
      existing.summary = summary;
      if (!summary.isStreaming && summary.pendingTurnId == null) {
        existing.streamingStatus = null;
      }
    }
  }

  void _setActive(String activeId) {
    _activeId = activeId;
    final conv = _conversations[activeId];
    if (conv == null || !conv.hasTranscript) {
      onNeedSnapshot?.call();
    }
  }

  void _applyMessagePage(MessagePage page) {
    final conv = _conversations[page.convId];
    if (conv == null) return;
    final bySeq = <int, Message>{
      for (final m in conv.messages) m.seq: m,
      for (final m in page.messages) m.seq: m,
    };
    conv.messages = bySeq.values.toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    // The page is older history: its cursor moves ours backwards only.
    if (conv.oldestSeq == null || page.oldestSeq <= conv.oldestSeq!) {
      conv.oldestSeq = page.oldestSeq;
      conv.hasOlderMessages = page.hasOlderMessages;
    }
  }

  void _insertMessage(ConversationData conv, Message message) {
    final bySeq = <int, Message>{
      for (final m in conv.messages) m.seq: m,
      message.seq: message,
    };
    conv.messages = bySeq.values.toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    conv.oldestSeq ??= message.seq;
  }
}
