/// Mirror-side state, driven exclusively by server envelopes (§3.4 of
/// PLAN.md / PLAN-D.md §3.4): `snapshot` keeps non-active transcripts,
/// `viewedId` is local, and a newest-page response replaces that
/// conversation's messages.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../protocol/protocol.dart';

final class ConversationData {
  ConversationSummary summary;

  /// Sorted ascending by `Message.seq`.
  List<Message> messages;

  /// Paging cursor (§3.6): next `request_messages.before_seq`. Null until a
  /// snapshot tail or newest page has arrived for this conversation.
  int? oldestSeq;
  bool hasOlderMessages;

  /// Set only by a snapshot tail or a newest-page response.
  bool transcriptLoaded;

  /// Set on every snapshot for conversations that are not the desktop active.
  bool transcriptStale;

  /// Assistant `message_complete` count while this tab is not viewed.
  int unread;

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
        hasOlderMessages = false,
        transcriptLoaded = false,
        transcriptStale = false,
        unread = 0;

  bool get hasTranscript => transcriptLoaded;
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
  String? _viewedId;
  bool followDesktop = false;
  final LinkedHashMap<String, PermissionRequest> _permissions =
      LinkedHashMap();
  final LinkedHashMap<int, ProposalData> _proposals = LinkedHashMap();
  RemoteSettings _settings = const RemoteSettings();
  final Set<String> _replaceTranscript = {};

  /// Viewing a conversation whose transcript is missing or stale.
  void Function(String convId)? onNeedNewestPage;

  /// The TUI restarted — drop everything; a fresh snapshot is coming.
  VoidCallback? onNeedSnapshot;

  /// Hooks for local notifications (B10).
  void Function(PermissionRequest request)? onPermissionRequested;
  void Function(StreamingEnded ended)? onStreamingEnded;

  /// One-shot signal for the review UI: a `proposal_updated` arrived.
  void Function(Proposal proposal)? onProposalUpdated;

  List<ConversationData> get conversations =>
      List.unmodifiable(_conversations.values);
  String? get activeId => _activeId;
  String? get viewedId => _viewedId;
  ConversationData? get active =>
      _activeId == null ? null : _conversations[_activeId];
  ConversationData? get viewed =>
      _viewedId == null ? null : _conversations[_viewedId];
  ConversationData? conversation(String convId) => _conversations[convId];
  List<PermissionRequest> get openPermissions =>
      List.unmodifiable(_permissions.values);
  List<PermissionRequest> get viewedPermissions => [
        for (final r in _permissions.values)
          if (r.convId == _viewedId) r
      ];
  int get otherPermissionCount => [
        for (final r in _permissions.values)
          if (r.convId != _viewedId) r
      ].length;
  PermissionRequest? get oldestOtherPermission {
    for (final r in _permissions.values) {
      if (r.convId != _viewedId) return r;
    }
    return null;
  }

  List<ProposalData> get openProposals =>
      List.unmodifiable(_proposals.values);
  ProposalData? proposal(int id) => _proposals[id];
  RemoteSettings get settings => _settings;

  /// The TUI restarted — drop everything; a fresh snapshot is coming.
  void clear() {
    _conversations.clear();
    _activeId = null;
    _viewedId = null;
    _permissions.clear();
    _proposals.clear();
    _replaceTranscript.clear();
    notifyListeners();
  }

  void expectNewestPage(String convId) {
    _replaceTranscript.add(convId);
  }

  void view(String convId) {
    _viewedId = convId;
    _conversations[convId]?.unread = 0;
    _maybeNeedNewest();
    notifyListeners();
  }

  void setFollowDesktop(bool value) {
    followDesktop = value;
    if (value && _activeId != null) {
      view(_activeId!);
    } else {
      notifyListeners();
    }
  }

  void applyEnvelope(ServerEnvelope envelope) {
    switch (envelope.payload) {
      case Hello():
        break; // Connection-level; controller learns workspace / directory.
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
          if (complete.convId != _viewedId) {
            conv.unread += 1;
          }
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
    final previous = Map<String, ConversationData>.from(_conversations);
    final fresh = <String, ConversationData>{};
    for (final summary in snapshot.conversations) {
      final existing = previous[summary.convId];
      if (existing != null) {
        existing.summary = summary;
        existing.transcriptStale = true;
        fresh[summary.convId] = existing;
      } else {
        fresh[summary.convId] = ConversationData(summary)
          ..transcriptStale = true;
      }
    }
    final activeState = snapshot.activeConversation;
    final activeData = fresh[activeState.summary.convId];
    if (activeData != null) {
      activeData.summary = activeState.summary;
      activeData.messages = [...activeState.messages]
        ..sort((a, b) => a.seq.compareTo(b.seq));
      activeData.oldestSeq = activeState.oldestSeq;
      activeData.hasOlderMessages = activeState.hasOlderMessages;
      activeData.transcriptLoaded = true;
      activeData.transcriptStale = false;
    }
    _conversations
      ..clear()
      ..addAll(fresh);
    _activeId = snapshot.activeId;
    if (followDesktop ||
        _viewedId == null ||
        !_conversations.containsKey(_viewedId)) {
      _viewedId = _activeId;
      if (_viewedId != null) _conversations[_viewedId]?.unread = 0;
    }
    _permissions.clear();
    for (final request in snapshot.openPermissions) {
      _permissions[request.requestId] = request;
    }
    _proposals.clear();
    for (final summary in snapshot.openProposals) {
      _proposals[summary.proposalId] = ProposalData(summary: summary);
    }
    _settings = snapshot.settings;
    _maybeNeedNewest();
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
    if (followDesktop ||
        _viewedId == null ||
        !_conversations.containsKey(_viewedId)) {
      _viewedId = activeId;
      _conversations[activeId]?.unread = 0;
      _maybeNeedNewest();
    }
  }

  void _maybeNeedNewest() {
    final id = _viewedId;
    if (id == null) return;
    final conv = _conversations[id];
    if (conv == null) return;
    if (!conv.transcriptLoaded || conv.transcriptStale) {
      onNeedNewestPage?.call(id);
    }
  }

  void _applyMessagePage(MessagePage page) {
    final conv = _conversations[page.convId];
    if (conv == null) return;
    if (_replaceTranscript.remove(page.convId)) {
      conv.messages = [...page.messages]
        ..sort((a, b) => a.seq.compareTo(b.seq));
      conv.oldestSeq = page.oldestSeq;
      conv.hasOlderMessages = page.hasOlderMessages;
      conv.transcriptLoaded = true;
      conv.transcriptStale = false;
      return;
    }
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
    // A live message on an unloaded conversation must not fake a cursor —
    // the first view still fetches the newest page.
    if (conv.transcriptLoaded) {
      conv.oldestSeq ??= message.seq;
    }
  }
}
