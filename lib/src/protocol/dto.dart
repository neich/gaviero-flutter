/// Data transfer objects for the gaviero.v1 wire protocol, hand-written
/// against the vendored `protocol/protocol.schema.json`.
///
/// Decoding rules (PROTOCOL.md): unknown fields are ignored; optional fields
/// are omitted on encode, never emitted as `null`.
library;

void _put(Map<String, Object?> map, String key, Object? value) {
  if (value != null) map[key] = value;
}

// ---------------------------------------------------------------------------
// hello

final class WorkspaceInfo {
  /// Hex workspace identity — never an absolute path.
  final String id;
  final String displayName;

  const WorkspaceInfo({required this.id, required this.displayName});

  factory WorkspaceInfo.fromJson(Map<String, Object?> json) => WorkspaceInfo(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
      );

  Map<String, Object?> toJson() => {'id': id, 'display_name': displayName};
}

final class Limits {
  final int maxFrameBytes;
  final int maxPromptBytes;
  final int commandRatePerSecond;

  const Limits({
    required this.maxFrameBytes,
    required this.maxPromptBytes,
    required this.commandRatePerSecond,
  });

  factory Limits.fromJson(Map<String, Object?> json) => Limits(
        maxFrameBytes: json['max_frame_bytes'] as int,
        maxPromptBytes: json['max_prompt_bytes'] as int,
        commandRatePerSecond: json['command_rate_per_second'] as int,
      );

  Map<String, Object?> toJson() => {
        'max_frame_bytes': maxFrameBytes,
        'max_prompt_bytes': maxPromptBytes,
        'command_rate_per_second': commandRatePerSecond,
      };
}

// ---------------------------------------------------------------------------
// conversations

final class ContextPressure {
  final int usedTokens;
  final int maxTokens;

  const ContextPressure({required this.usedTokens, required this.maxTokens});

  factory ContextPressure.fromJson(Map<String, Object?> json) =>
      ContextPressure(
        usedTokens: json['used_tokens'] as int,
        maxTokens: json['max_tokens'] as int,
      );

  Map<String, Object?> toJson() =>
      {'used_tokens': usedTokens, 'max_tokens': maxTokens};

  double get ratio => maxTokens == 0 ? 0 : usedTokens / maxTokens;
}

final class ConversationSummary {
  final String convId;

  /// Freshness token for `rename_conversation` / `reset_conversation`.
  final int convRevision;
  final String title;

  /// Full `provider:model` spec.
  final String? model;
  final String? effort;
  final String? namespace;
  final bool isStreaming;
  final String? pendingTurnId;
  final ContextPressure? contextPressure;
  final bool autoApprove;
  final String? lastMessagePreview;

  const ConversationSummary({
    required this.convId,
    required this.convRevision,
    required this.title,
    this.model,
    this.effort,
    this.namespace,
    required this.isStreaming,
    this.pendingTurnId,
    this.contextPressure,
    required this.autoApprove,
    this.lastMessagePreview,
  });

  factory ConversationSummary.fromJson(Map<String, Object?> json) =>
      ConversationSummary(
        convId: json['conv_id'] as String,
        convRevision: json['conv_revision'] as int,
        title: json['title'] as String,
        model: json['model'] as String?,
        effort: json['effort'] as String?,
        namespace: json['namespace'] as String?,
        isStreaming: json['is_streaming'] as bool,
        pendingTurnId: json['pending_turn_id'] as String?,
        contextPressure: json['context_pressure'] == null
            ? null
            : ContextPressure.fromJson(
                json['context_pressure'] as Map<String, Object?>),
        autoApprove: json['auto_approve'] as bool,
        lastMessagePreview: json['last_message_preview'] as String?,
      );

  Map<String, Object?> toJson() {
    final map = <String, Object?>{
      'conv_id': convId,
      'conv_revision': convRevision,
      'title': title,
    };
    _put(map, 'model', model);
    _put(map, 'effort', effort);
    _put(map, 'namespace', namespace);
    map['is_streaming'] = isStreaming;
    _put(map, 'pending_turn_id', pendingTurnId);
    _put(map, 'context_pressure', contextPressure?.toJson());
    map['auto_approve'] = autoApprove;
    _put(map, 'last_message_preview', lastMessagePreview);
    return map;
  }
}

// ---------------------------------------------------------------------------
// messages

enum Role {
  user,
  assistant,
  system;

  static Role fromWire(String s) => switch (s) {
        'user' => user,
        'assistant' => assistant,
        'system' => system,
        _ => throw FormatException('unknown role: $s'),
      };

  String get wire => name;
}

/// All offsets are UTF-8 byte offsets into `Message.content`, ends exclusive,
/// absolute (not block-relative). Never slice with `String.substring`.
final class Span {
  final int startByte;
  final int endByte;

  /// Semantic tree-sitter capture name (`keyword`, `string`, …). Unknown
  /// classes render as plain text.
  final String className;

  const Span({
    required this.startByte,
    required this.endByte,
    required this.className,
  });

  factory Span.fromJson(Map<String, Object?> json) => Span(
        startByte: json['start_byte'] as int,
        endByte: json['end_byte'] as int,
        className: json['class'] as String,
      );

  Map<String, Object?> toJson() =>
      {'start_byte': startByte, 'end_byte': endByte, 'class': className};
}

final class CodeBlock {
  /// Range of the entire fenced block, fences included.
  final int startByte;
  final int endByte;
  final String? language;

  /// True ⇒ block over 256 KiB: no spans, render plain.
  final bool truncated;
  final List<Span> spans;

  const CodeBlock({
    required this.startByte,
    required this.endByte,
    this.language,
    required this.truncated,
    required this.spans,
  });

  factory CodeBlock.fromJson(Map<String, Object?> json) => CodeBlock(
        startByte: json['start_byte'] as int,
        endByte: json['end_byte'] as int,
        language: json['language'] as String?,
        truncated: json['truncated'] as bool,
        spans: [
          for (final s in json['spans'] as List<Object?>)
            Span.fromJson(s as Map<String, Object?>)
        ],
      );

  Map<String, Object?> toJson() {
    final map = <String, Object?>{
      'start_byte': startByte,
      'end_byte': endByte,
    };
    _put(map, 'language', language);
    map['truncated'] = truncated;
    map['spans'] = [for (final s in spans) s.toJson()];
    return map;
  }
}

final class Message {
  /// Monotonic per-conversation id; survives /compact and /reset.
  /// NOT the envelope `seq`.
  final int seq;
  final Role role;
  final String content;

  /// True ⇒ `content` is the head of a >128 KiB message.
  final bool truncated;
  final int? fullBytes;
  final List<String> toolCalls;
  final List<CodeBlock> codeBlocks;

  const Message({
    required this.seq,
    required this.role,
    required this.content,
    required this.truncated,
    this.fullBytes,
    required this.toolCalls,
    required this.codeBlocks,
  });

  factory Message.fromJson(Map<String, Object?> json) => Message(
        seq: json['seq'] as int,
        role: Role.fromWire(json['role'] as String),
        content: json['content'] as String,
        truncated: json['truncated'] as bool,
        fullBytes: json['full_bytes'] as int?,
        toolCalls: [
          for (final t in json['tool_calls'] as List<Object?>) t as String
        ],
        codeBlocks: [
          for (final b in json['code_blocks'] as List<Object?>)
            CodeBlock.fromJson(b as Map<String, Object?>)
        ],
      );

  Map<String, Object?> toJson() {
    final map = <String, Object?>{
      'seq': seq,
      'role': role.wire,
      'content': content,
      'truncated': truncated,
    };
    _put(map, 'full_bytes', fullBytes);
    map['tool_calls'] = toolCalls;
    map['code_blocks'] = [for (final b in codeBlocks) b.toJson()];
    return map;
  }
}

final class ConversationState {
  final ConversationSummary summary;

  /// At most the latest 100 messages / 512 KiB encoded.
  final List<Message> messages;

  /// When `messages` is empty this echoes the requested cursor.
  final int oldestSeq;
  final bool hasOlderMessages;

  const ConversationState({
    required this.summary,
    required this.messages,
    required this.oldestSeq,
    required this.hasOlderMessages,
  });

  factory ConversationState.fromJson(Map<String, Object?> json) =>
      ConversationState(
        summary: ConversationSummary.fromJson(
            json['summary'] as Map<String, Object?>),
        messages: [
          for (final m in json['messages'] as List<Object?>)
            Message.fromJson(m as Map<String, Object?>)
        ],
        oldestSeq: json['oldest_seq'] as int,
        hasOlderMessages: json['has_older_messages'] as bool,
      );

  Map<String, Object?> toJson() => {
        'summary': summary.toJson(),
        'messages': [for (final m in messages) m.toJson()],
        'oldest_seq': oldestSeq,
        'has_older_messages': hasOlderMessages,
      };
}

// ---------------------------------------------------------------------------
// permissions

final class AskOption {
  final String label;
  final String description;

  const AskOption({required this.label, required this.description});

  factory AskOption.fromJson(Map<String, Object?> json) => AskOption(
        label: json['label'] as String,
        description: json['description'] as String,
      );

  Map<String, Object?> toJson() =>
      {'label': label, 'description': description};
}

final class AskQuestion {
  final String question;
  final String header;
  final bool multiSelect;
  final List<AskOption> options;

  const AskQuestion({
    required this.question,
    required this.header,
    required this.multiSelect,
    required this.options,
  });

  factory AskQuestion.fromJson(Map<String, Object?> json) => AskQuestion(
        question: json['question'] as String,
        header: json['header'] as String,
        multiSelect: json['multi_select'] as bool,
        options: [
          for (final o in json['options'] as List<Object?>)
            AskOption.fromJson(o as Map<String, Object?>)
        ],
      );

  Map<String, Object?> toJson() => {
        'question': question,
        'header': header,
        'multi_select': multiSelect,
        'options': [for (final o in options) o.toJson()],
      };
}

final class Ask {
  final List<AskQuestion> questions;

  const Ask({required this.questions});

  factory Ask.fromJson(Map<String, Object?> json) => Ask(questions: [
        for (final q in json['questions'] as List<Object?>)
          AskQuestion.fromJson(q as Map<String, Object?>)
      ]);

  Map<String, Object?> toJson() =>
      {'questions': [for (final q in questions) q.toJson()]};
}

final class PermissionRequest {
  final String convId;

  /// Freshness token for `permission_decision`.
  final String requestId;
  final String toolName;
  final String description;

  /// Display-only. The client never sends tool input back.
  final Object? input;
  final Ask? ask;

  const PermissionRequest({
    required this.convId,
    required this.requestId,
    required this.toolName,
    required this.description,
    required this.input,
    this.ask,
  });

  factory PermissionRequest.fromJson(Map<String, Object?> json) =>
      PermissionRequest(
        convId: json['conv_id'] as String,
        requestId: json['request_id'] as String,
        toolName: json['tool_name'] as String,
        description: json['description'] as String,
        input: json['input'],
        ask: json['ask'] == null
            ? null
            : Ask.fromJson(json['ask'] as Map<String, Object?>),
      );

  Map<String, Object?> toJson() {
    final map = <String, Object?>{
      'conv_id': convId,
      'request_id': requestId,
      'tool_name': toolName,
      'description': description,
      'input': input,
    };
    _put(map, 'ask', ask?.toJson());
    return map;
  }
}

enum PermissionOutcome {
  allowed,
  denied,
  superseded,
  cancelled;

  static PermissionOutcome fromWire(String s) => switch (s) {
        'allowed' => allowed,
        'denied' => denied,
        'superseded' => superseded,
        'cancelled' => cancelled,
        _ => throw FormatException('unknown permission outcome: $s'),
      };

  String get wire => name;
}

enum AnsweredBy {
  desktop,
  remote,
  system;

  static AnsweredBy fromWire(String s) => switch (s) {
        'desktop' => desktop,
        'remote' => remote,
        'system' => system,
        _ => throw FormatException('unknown answered_by: $s'),
      };

  String get wire => name;
}

// ---------------------------------------------------------------------------
// proposals

/// 0-indexed line numbers, display-only.
final class LineRange {
  final int startLine;
  final int endLine;

  const LineRange({required this.startLine, required this.endLine});

  factory LineRange.fromJson(Map<String, Object?> json) => LineRange(
        startLine: json['start_line'] as int,
        endLine: json['end_line'] as int,
      );

  Map<String, Object?> toJson() =>
      {'start_line': startLine, 'end_line': endLine};
}

enum HunkType {
  added,
  removed,
  modified;

  static HunkType fromWire(String s) => switch (s) {
        'added' => added,
        'removed' => removed,
        'modified' => modified,
        _ => throw FormatException('unknown hunk type: $s'),
      };

  String get wire => name;
}

enum HunkStatus {
  pending,
  accepted,
  rejected;

  static HunkStatus fromWire(String s) => switch (s) {
        'pending' => pending,
        'accepted' => accepted,
        'rejected' => rejected,
        _ => throw FormatException('unknown hunk status: $s'),
      };

  String get wire => name;
}

final class Hunk {
  /// Stable for the proposal lifetime; echoed by `review_action`.
  final int index;
  final LineRange originalRange;
  final LineRange proposedRange;
  final String originalText;
  final String proposedText;

  /// True ⇒ text elided (over 64 KiB per side). Still reviewable: the server
  /// assembles from its own copy.
  final bool truncated;
  final HunkType hunkType;
  final String description;
  final HunkStatus status;

  const Hunk({
    required this.index,
    required this.originalRange,
    required this.proposedRange,
    required this.originalText,
    required this.proposedText,
    required this.truncated,
    required this.hunkType,
    required this.description,
    required this.status,
  });

  factory Hunk.fromJson(Map<String, Object?> json) => Hunk(
        index: json['index'] as int,
        originalRange:
            LineRange.fromJson(json['original_range'] as Map<String, Object?>),
        proposedRange:
            LineRange.fromJson(json['proposed_range'] as Map<String, Object?>),
        originalText: json['original_text'] as String,
        proposedText: json['proposed_text'] as String,
        truncated: json['truncated'] as bool,
        hunkType: HunkType.fromWire(json['hunk_type'] as String),
        description: json['description'] as String,
        status: HunkStatus.fromWire(json['status'] as String),
      );

  Map<String, Object?> toJson() => {
        'index': index,
        'original_range': originalRange.toJson(),
        'proposed_range': proposedRange.toJson(),
        'original_text': originalText,
        'proposed_text': proposedText,
        'truncated': truncated,
        'hunk_type': hunkType.wire,
        'description': description,
        'status': status.wire,
      };
}

final class HunkSummary {
  final int index;
  final HunkType hunkType;
  final String description;
  final HunkStatus status;

  const HunkSummary({
    required this.index,
    required this.hunkType,
    required this.description,
    required this.status,
  });

  factory HunkSummary.fromJson(Map<String, Object?> json) => HunkSummary(
        index: json['index'] as int,
        hunkType: HunkType.fromWire(json['hunk_type'] as String),
        description: json['description'] as String,
        status: HunkStatus.fromWire(json['status'] as String),
      );

  Map<String, Object?> toJson() => {
        'index': index,
        'hunk_type': hunkType.wire,
        'description': description,
        'status': status.wire,
      };
}

enum ProposalStatus {
  pending,
  partiallyAccepted,
  accepted,
  rejected,
  superseded;

  static ProposalStatus fromWire(String s) => switch (s) {
        'pending' => pending,
        'partially_accepted' => partiallyAccepted,
        'accepted' => accepted,
        'rejected' => rejected,
        'superseded' => superseded,
        _ => throw FormatException('unknown proposal status: $s'),
      };

  String get wire => switch (this) {
        pending => 'pending',
        partiallyAccepted => 'partially_accepted',
        accepted => 'accepted',
        rejected => 'rejected',
        superseded => 'superseded',
      };
}

final class Proposal {
  final int proposalId;

  /// Freshness token for `review_action`.
  final int proposalRevision;
  final String? convId;
  final String source;

  /// Workspace-relative.
  final String path;
  final ProposalStatus status;
  final bool isDeletion;
  final List<int> conflictsWith;
  final List<Hunk> hunks;

  const Proposal({
    required this.proposalId,
    required this.proposalRevision,
    this.convId,
    required this.source,
    required this.path,
    required this.status,
    required this.isDeletion,
    required this.conflictsWith,
    required this.hunks,
  });

  factory Proposal.fromJson(Map<String, Object?> json) => Proposal(
        proposalId: json['proposal_id'] as int,
        proposalRevision: json['proposal_revision'] as int,
        convId: json['conv_id'] as String?,
        source: json['source'] as String,
        path: json['path'] as String,
        status: ProposalStatus.fromWire(json['status'] as String),
        isDeletion: json['is_deletion'] as bool,
        conflictsWith: [
          for (final c in json['conflicts_with'] as List<Object?>) c as int
        ],
        hunks: [
          for (final h in json['hunks'] as List<Object?>)
            Hunk.fromJson(h as Map<String, Object?>)
        ],
      );

  Map<String, Object?> toJson() {
    final map = <String, Object?>{
      'proposal_id': proposalId,
      'proposal_revision': proposalRevision,
    };
    _put(map, 'conv_id', convId);
    map['source'] = source;
    map['path'] = path;
    map['status'] = status.wire;
    map['is_deletion'] = isDeletion;
    map['conflicts_with'] = conflictsWith;
    map['hunks'] = [for (final h in hunks) h.toJson()];
    return map;
  }
}

/// Snapshot form: never carries hunk text.
final class ProposalSummary {
  final int proposalId;
  final int proposalRevision;
  final String? convId;
  final String source;
  final String path;
  final ProposalStatus status;
  final bool isDeletion;
  final List<int> conflictsWith;
  final int hunkCount;
  final int addedLines;
  final int removedLines;
  final List<HunkSummary> hunks;

  const ProposalSummary({
    required this.proposalId,
    required this.proposalRevision,
    this.convId,
    required this.source,
    required this.path,
    required this.status,
    required this.isDeletion,
    required this.conflictsWith,
    required this.hunkCount,
    required this.addedLines,
    required this.removedLines,
    required this.hunks,
  });

  factory ProposalSummary.fromJson(Map<String, Object?> json) =>
      ProposalSummary(
        proposalId: json['proposal_id'] as int,
        proposalRevision: json['proposal_revision'] as int,
        convId: json['conv_id'] as String?,
        source: json['source'] as String,
        path: json['path'] as String,
        status: ProposalStatus.fromWire(json['status'] as String),
        isDeletion: json['is_deletion'] as bool,
        conflictsWith: [
          for (final c in json['conflicts_with'] as List<Object?>) c as int
        ],
        hunkCount: json['hunk_count'] as int,
        addedLines: json['added_lines'] as int,
        removedLines: json['removed_lines'] as int,
        hunks: [
          for (final h in json['hunks'] as List<Object?>)
            HunkSummary.fromJson(h as Map<String, Object?>)
        ],
      );

  Map<String, Object?> toJson() {
    final map = <String, Object?>{
      'proposal_id': proposalId,
      'proposal_revision': proposalRevision,
    };
    _put(map, 'conv_id', convId);
    map['source'] = source;
    map['path'] = path;
    map['status'] = status.wire;
    map['is_deletion'] = isDeletion;
    map['conflicts_with'] = conflictsWith;
    map['hunk_count'] = hunkCount;
    map['added_lines'] = addedLines;
    map['removed_lines'] = removedLines;
    map['hunks'] = [for (final h in hunks) h.toJson()];
    return map;
  }
}

enum ProposalOutcome {
  accepted,
  partiallyAccepted,
  rejected;

  static ProposalOutcome fromWire(String s) => switch (s) {
        'accepted' => accepted,
        'partially_accepted' => partiallyAccepted,
        'rejected' => rejected,
        _ => throw FormatException('unknown proposal outcome: $s'),
      };

  String get wire => switch (this) {
        accepted => 'accepted',
        partiallyAccepted => 'partially_accepted',
        rejected => 'rejected',
      };
}

// ---------------------------------------------------------------------------
// snapshot

/// Explicit allow-list DTO — never raw workspace settings.
final class RemoteSettings {
  final String? defaultModel;
  final String? defaultEffort;

  const RemoteSettings({this.defaultModel, this.defaultEffort});

  factory RemoteSettings.fromJson(Map<String, Object?> json) => RemoteSettings(
        defaultModel: json['default_model'] as String?,
        defaultEffort: json['default_effort'] as String?,
      );

  Map<String, Object?> toJson() {
    final map = <String, Object?>{};
    _put(map, 'default_model', defaultModel);
    _put(map, 'default_effort', defaultEffort);
    return map;
  }
}

// ---------------------------------------------------------------------------
// usage

final class TokenUsage {
  final int inputTokens;
  final int cacheCreationInputTokens;
  final int cacheReadInputTokens;
  final int outputTokens;

  const TokenUsage({
    required this.inputTokens,
    required this.cacheCreationInputTokens,
    required this.cacheReadInputTokens,
    required this.outputTokens,
  });

  factory TokenUsage.fromJson(Map<String, Object?> json) => TokenUsage(
        inputTokens: json['input_tokens'] as int,
        cacheCreationInputTokens: json['cache_creation_input_tokens'] as int,
        cacheReadInputTokens: json['cache_read_input_tokens'] as int,
        outputTokens: json['output_tokens'] as int,
      );

  Map<String, Object?> toJson() => {
        'input_tokens': inputTokens,
        'cache_creation_input_tokens': cacheCreationInputTokens,
        'cache_read_input_tokens': cacheReadInputTokens,
        'output_tokens': outputTokens,
      };
}

// ---------------------------------------------------------------------------
// command correlation

enum CommandStatus {
  /// Fully done.
  completed,

  /// Terminal: validated and started; outcome arrives as lifecycle events
  /// keyed by ids in `result`. Never followed by `completed`.
  accepted;

  static CommandStatus fromWire(String s) => switch (s) {
        'completed' => completed,
        'accepted' => accepted,
        _ => throw FormatException('unknown command status: $s'),
      };

  String get wire => name;
}

/// `command_error.code`. The set is frozen for 1.0 but additions are minor
/// bumps, so an unrecognized code decodes to [unrecognized] with the raw
/// string preserved rather than failing the frame.
enum ErrorCode {
  invalidPayload('invalid_payload'),
  unknownType('unknown_type'),
  unknownConversation('unknown_conversation'),
  unknownRequest('unknown_request'),
  unknownProposal('unknown_proposal'),
  invalidHunk('invalid_hunk'),
  staleRequest('stale_request'),
  staleProposal('stale_proposal'),
  staleConversation('stale_conversation'),
  conversationStreaming('conversation_streaming'),
  slashNotAllowed('slash_not_allowed'),
  confirmRequired('confirm_required'),
  tooLarge('too_large'),
  rateLimited('rate_limited'),
  duplicateCommand('duplicate_command'),
  internalError('internal_error'),
  unrecognized('unrecognized');

  final String wire;
  const ErrorCode(this.wire);

  static ErrorCode fromWire(String s) => values.firstWhere(
        (c) => c.wire == s,
        orElse: () => unrecognized,
      );
}
