/// Client → server frame payloads (16 types).
library;

import 'version.dart';

void _put(Map<String, Object?> map, String key, Object? value) {
  if (value != null) map[key] = value;
}

sealed class ClientPayload {
  const ClientPayload();

  String get frameType;
  Map<String, Object?> toPayloadJson();

  static ClientPayload fromJson(String type, Map<String, Object?> json) =>
      switch (type) {
        'client_hello' => ClientHello.fromJson(json),
        'send_prompt' => SendPrompt.fromJson(json),
        'slash' => Slash.fromJson(json),
        'permission_decision' => PermissionDecision.fromJson(json),
        'review_action' => ReviewAction.fromJson(json),
        'new_conversation' => const NewConversation(),
        'switch_conversation' => SwitchConversation.fromJson(json),
        'rename_conversation' => RenameConversation.fromJson(json),
        'reset_conversation' => ResetConversation.fromJson(json),
        'interrupt' => Interrupt.fromJson(json),
        'request_snapshot' => const RequestSnapshot(),
        'request_messages' => RequestMessages.fromJson(json),
        'request_proposal' => RequestProposal.fromJson(json),
        'request_terminals' => RequestTerminals(terminalId: json['terminal_id'] as int?),
        'terminal_input' => TerminalInput(
            terminalId: json['terminal_id'] as int, text: json['text'] as String),
        'request_file_completions' => RequestFileCompletions(
            query: json['query'] as String, limit: json['limit'] as int?),
        _ => throw FormatException('unknown client frame type: $type'),
      };
}

final class RequestTerminals extends ClientPayload {
  final int? terminalId;
  const RequestTerminals({this.terminalId});

  @override
  String get frameType => 'request_terminals';

  @override
  Map<String, Object?> toPayloadJson() => {
    if (terminalId != null) 'terminal_id': terminalId,
  };
}

final class TerminalInput extends ClientPayload {
  final int terminalId;
  final String text;
  const TerminalInput({required this.terminalId, required this.text});

  @override
  String get frameType => 'terminal_input';

  @override
  Map<String, Object?> toPayloadJson() => {'terminal_id': terminalId, 'text': text};
}

/// Requires [Capability.fileCompletions]. The completed result is
/// `{query, files: [string]}` with workspace-relative paths.
final class RequestFileCompletions extends ClientPayload {
  /// Text typed after `@`, without the `@`. At most 1024 bytes.
  final String query;

  /// Clamped server-side to 1–50; null ⇒ omitted ⇒ 10.
  final int? limit;

  const RequestFileCompletions({required this.query, this.limit});

  @override
  String get frameType => 'request_file_completions';

  @override
  Map<String, Object?> toPayloadJson() {
    final map = <String, Object?>{'query': query};
    _put(map, 'limit', limit);
    return map;
  }
}

final class ClientHello extends ClientPayload {
  final ProtocolVersion protocolVersion;
  final String clientName;
  final String clientVersion;

  const ClientHello({
    required this.protocolVersion,
    required this.clientName,
    required this.clientVersion,
  });

  factory ClientHello.fromJson(Map<String, Object?> json) => ClientHello(
        protocolVersion: ProtocolVersion.fromJson(
            json['protocol_version'] as Map<String, Object?>),
        clientName: json['client_name'] as String,
        clientVersion: json['client_version'] as String,
      );

  @override
  String get frameType => 'client_hello';

  @override
  Map<String, Object?> toPayloadJson() => {
        'protocol_version': protocolVersion.toJson(),
        'client_name': clientName,
        'client_version': clientVersion,
      };
}

final class SendPrompt extends ClientPayload {
  final String convId;
  final String text;

  const SendPrompt({required this.convId, required this.text});

  factory SendPrompt.fromJson(Map<String, Object?> json) => SendPrompt(
        convId: json['conv_id'] as String,
        text: json['text'] as String,
      );

  @override
  String get frameType => 'send_prompt';

  @override
  Map<String, Object?> toPayloadJson() => {'conv_id': convId, 'text': text};
}

final class Slash extends ClientPayload {
  final String convId;
  final String line;

  /// Must be true for commands listed in `hello.confirm_required`.
  final bool confirmed;

  const Slash({
    required this.convId,
    required this.line,
    required this.confirmed,
  });

  factory Slash.fromJson(Map<String, Object?> json) => Slash(
        convId: json['conv_id'] as String,
        line: json['line'] as String,
        confirmed: json['confirmed'] as bool,
      );

  @override
  String get frameType => 'slash';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'line': line, 'confirmed': confirmed};
}

final class PermissionDecision extends ClientPayload {
  final String requestId;
  final bool allow;

  /// Per question, selected option indices. Only for `AskUserQuestion`
  /// permissions; never a tool-input document.
  final List<List<int>>? answers;

  /// Free text on deny.
  final String? message;

  const PermissionDecision({
    required this.requestId,
    required this.allow,
    this.answers,
    this.message,
  });

  factory PermissionDecision.fromJson(Map<String, Object?> json) =>
      PermissionDecision(
        requestId: json['request_id'] as String,
        allow: json['allow'] as bool,
        answers: json['answers'] == null
            ? null
            : [
                for (final q in json['answers'] as List<Object?>)
                  [for (final i in q as List<Object?>) i as int]
              ],
        message: json['message'] as String?,
      );

  @override
  String get frameType => 'permission_decision';

  @override
  Map<String, Object?> toPayloadJson() {
    final map = <String, Object?>{'request_id': requestId, 'allow': allow};
    _put(map, 'answers', answers);
    _put(map, 'message', message);
    return map;
  }
}

enum ReviewActionKind {
  acceptHunk('accept_hunk'),
  rejectHunk('reject_hunk'),
  acceptAll('accept_all'),
  rejectAll('reject_all'),
  finalize('finalize');

  final String wire;
  const ReviewActionKind(this.wire);

  static ReviewActionKind fromWire(String s) => values.firstWhere(
        (k) => k.wire == s,
        orElse: () => throw FormatException('unknown review action: $s'),
      );
}

final class ReviewAction extends ClientPayload {
  final int proposalId;
  final int proposalRevision;
  final ReviewActionKind action;

  /// Required for `accept_hunk` / `reject_hunk`.
  final int? hunkIndex;

  const ReviewAction({
    required this.proposalId,
    required this.proposalRevision,
    required this.action,
    this.hunkIndex,
  });

  factory ReviewAction.fromJson(Map<String, Object?> json) => ReviewAction(
        proposalId: json['proposal_id'] as int,
        proposalRevision: json['proposal_revision'] as int,
        action: ReviewActionKind.fromWire(json['action'] as String),
        hunkIndex: json['hunk_index'] as int?,
      );

  @override
  String get frameType => 'review_action';

  @override
  Map<String, Object?> toPayloadJson() {
    final map = <String, Object?>{
      'proposal_id': proposalId,
      'proposal_revision': proposalRevision,
      'action': action.wire,
    };
    _put(map, 'hunk_index', hunkIndex);
    return map;
  }
}

final class NewConversation extends ClientPayload {
  const NewConversation();

  @override
  String get frameType => 'new_conversation';

  @override
  Map<String, Object?> toPayloadJson() => {};
}

final class SwitchConversation extends ClientPayload {
  final String convId;

  const SwitchConversation({required this.convId});

  factory SwitchConversation.fromJson(Map<String, Object?> json) =>
      SwitchConversation(convId: json['conv_id'] as String);

  @override
  String get frameType => 'switch_conversation';

  @override
  Map<String, Object?> toPayloadJson() => {'conv_id': convId};
}

final class RenameConversation extends ClientPayload {
  final String convId;
  final int convRevision;
  final String title;

  const RenameConversation({
    required this.convId,
    required this.convRevision,
    required this.title,
  });

  factory RenameConversation.fromJson(Map<String, Object?> json) =>
      RenameConversation(
        convId: json['conv_id'] as String,
        convRevision: json['conv_revision'] as int,
        title: json['title'] as String,
      );

  @override
  String get frameType => 'rename_conversation';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'conv_revision': convRevision, 'title': title};
}

final class ResetConversation extends ClientPayload {
  final String convId;
  final int convRevision;

  const ResetConversation({required this.convId, required this.convRevision});

  factory ResetConversation.fromJson(Map<String, Object?> json) =>
      ResetConversation(
        convId: json['conv_id'] as String,
        convRevision: json['conv_revision'] as int,
      );

  @override
  String get frameType => 'reset_conversation';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'conv_revision': convRevision};
}

final class Interrupt extends ClientPayload {
  final String convId;
  final String? turnId;

  const Interrupt({required this.convId, this.turnId});

  factory Interrupt.fromJson(Map<String, Object?> json) => Interrupt(
        convId: json['conv_id'] as String,
        turnId: json['turn_id'] as String?,
      );

  @override
  String get frameType => 'interrupt';

  @override
  Map<String, Object?> toPayloadJson() {
    final map = <String, Object?>{'conv_id': convId};
    _put(map, 'turn_id', turnId);
    return map;
  }
}

final class RequestSnapshot extends ClientPayload {
  const RequestSnapshot();

  @override
  String get frameType => 'request_snapshot';

  @override
  Map<String, Object?> toPayloadJson() => {};
}

final class RequestMessages extends ClientPayload {
  final String convId;

  /// Paging cursor. Optional since 1.1 (`latest_page`): null ⇒ omitted from
  /// the wire ⇒ the newest page. A 1.0 server requires it — send
  /// [legacyNewestPageBeforeSeq] there instead.
  final int? beforeSeq;

  /// Clamped server-side to 1–200.
  final int limit;

  const RequestMessages({
    required this.convId,
    this.beforeSeq,
    required this.limit,
  });

  factory RequestMessages.fromJson(Map<String, Object?> json) =>
      RequestMessages(
        convId: json['conv_id'] as String,
        beforeSeq: json['before_seq'] as int?,
        limit: json['limit'] as int,
      );

  @override
  String get frameType => 'request_messages';

  @override
  Map<String, Object?> toPayloadJson() {
    final map = <String, Object?>{'conv_id': convId};
    _put(map, 'before_seq', beforeSeq);
    map['limit'] = limit;
    return map;
  }
}

final class RequestProposal extends ClientPayload {
  final int proposalId;

  const RequestProposal({required this.proposalId});

  factory RequestProposal.fromJson(Map<String, Object?> json) =>
      RequestProposal(proposalId: json['proposal_id'] as int);

  @override
  String get frameType => 'request_proposal';

  @override
  Map<String, Object?> toPayloadJson() => {'proposal_id': proposalId};
}
