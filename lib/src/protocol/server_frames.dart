/// Server → client frame payloads (20 types + unknown-type fallback).
library;

import 'dto.dart';
import 'version.dart';

void _put(Map<String, Object?> map, String key, Object? value) {
  if (value != null) map[key] = value;
}

sealed class ServerPayload {
  const ServerPayload();

  String get frameType;
  Map<String, Object?> toPayloadJson();

  /// Unknown types decode to [UnknownServerPayload] — never a crash
  /// (minor-version forward compatibility).
  static ServerPayload fromJson(String type, Map<String, Object?> json) =>
      switch (type) {
        'hello' => Hello.fromJson(json),
        'snapshot' => Snapshot.fromJson(json),
        'conversation_state_changed' => ConversationStateChanged.fromJson(json),
        'conversation_removed' => ConversationRemoved.fromJson(json),
        'message_page' => MessagePage.fromJson(json),
        'stream_chunk' => StreamChunk.fromJson(json),
        'streaming_status' => StreamingStatus.fromJson(json),
        'streaming_ended' => StreamingEnded.fromJson(json),
        'tool_call_started' => ToolCallStarted.fromJson(json),
        'message_complete' => MessageComplete.fromJson(json),
        'permission_request' => PermissionRequestFrame.fromJson(json),
        'permission_closed' => PermissionClosed.fromJson(json),
        'proposal_created' =>
          ProposalEvent.fromJson(ProposalLifecycle.created, json),
        'proposal_updated' =>
          ProposalEvent.fromJson(ProposalLifecycle.updated, json),
        'proposal_detail' =>
          ProposalEvent.fromJson(ProposalLifecycle.detail, json),
        'proposal_finalized' => ProposalFinalized.fromJson(json),
        'token_usage' => TokenUsageEvent.fromJson(json),
        'cost_update' => CostUpdate.fromJson(json),
        'command_result' => CommandResult.fromJson(json),
        'command_error' => CommandError.fromJson(json),
        _ => UnknownServerPayload(type, json),
      };
}

/// A frame type this client does not know. Ignored with a warning upstream.
final class UnknownServerPayload extends ServerPayload {
  final String type;
  final Map<String, Object?> payload;

  const UnknownServerPayload(this.type, this.payload);

  @override
  String get frameType => type;

  @override
  Map<String, Object?> toPayloadJson() => payload;
}

final class Hello extends ServerPayload {
  final ProtocolVersion serverProtocolVersion;
  final String instanceId;
  final String tuiVersion;
  final WorkspaceInfo workspace;

  /// Frozen shape, empty in 1.0. Unknown entries are ignored.
  final List<String> capabilities;
  final List<String> confirmRequired;
  final List<String> allowedSlashCommands;
  final Limits limits;

  const Hello({
    required this.serverProtocolVersion,
    required this.instanceId,
    required this.tuiVersion,
    required this.workspace,
    required this.capabilities,
    required this.confirmRequired,
    required this.allowedSlashCommands,
    required this.limits,
  });

  factory Hello.fromJson(Map<String, Object?> json) => Hello(
        serverProtocolVersion: ProtocolVersion.fromJson(
            json['protocol_version'] as Map<String, Object?>),
        instanceId: json['instance_id'] as String,
        tuiVersion: json['tui_version'] as String,
        workspace:
            WorkspaceInfo.fromJson(json['workspace'] as Map<String, Object?>),
        capabilities: [
          for (final c in json['capabilities'] as List<Object?>) c as String
        ],
        confirmRequired: [
          for (final c in json['confirm_required'] as List<Object?>)
            c as String
        ],
        allowedSlashCommands: [
          for (final c in json['allowed_slash_commands'] as List<Object?>)
            c as String
        ],
        limits: Limits.fromJson(json['limits'] as Map<String, Object?>),
      );

  @override
  String get frameType => 'hello';

  @override
  Map<String, Object?> toPayloadJson() => {
        'protocol_version': serverProtocolVersion.toJson(),
        'instance_id': instanceId,
        'tui_version': tuiVersion,
        'workspace': workspace.toJson(),
        'capabilities': capabilities,
        'confirm_required': confirmRequired,
        'allowed_slash_commands': allowedSlashCommands,
        'limits': limits.toJson(),
      };
}

final class Snapshot extends ServerPayload {
  final int revision;
  final List<ConversationSummary> conversations;
  final String activeId;
  final ConversationState activeConversation;
  final List<PermissionRequest> openPermissions;
  final List<ProposalSummary> openProposals;
  final RemoteSettings settings;

  const Snapshot({
    required this.revision,
    required this.conversations,
    required this.activeId,
    required this.activeConversation,
    required this.openPermissions,
    required this.openProposals,
    required this.settings,
  });

  factory Snapshot.fromJson(Map<String, Object?> json) => Snapshot(
        revision: json['revision'] as int,
        conversations: [
          for (final c in json['conversations'] as List<Object?>)
            ConversationSummary.fromJson(c as Map<String, Object?>)
        ],
        activeId: json['active_id'] as String,
        activeConversation: ConversationState.fromJson(
            json['active_conversation'] as Map<String, Object?>),
        openPermissions: [
          for (final p in json['open_permissions'] as List<Object?>)
            PermissionRequest.fromJson(p as Map<String, Object?>)
        ],
        openProposals: [
          for (final p in json['open_proposals'] as List<Object?>)
            ProposalSummary.fromJson(p as Map<String, Object?>)
        ],
        settings:
            RemoteSettings.fromJson(json['settings'] as Map<String, Object?>),
      );

  @override
  String get frameType => 'snapshot';

  @override
  Map<String, Object?> toPayloadJson() => {
        'revision': revision,
        'conversations': [for (final c in conversations) c.toJson()],
        'active_id': activeId,
        'active_conversation': activeConversation.toJson(),
        'open_permissions': [for (final p in openPermissions) p.toJson()],
        'open_proposals': [for (final p in openProposals) p.toJson()],
        'settings': settings.toJson(),
      };
}

final class ConversationStateChanged extends ServerPayload {
  final ConversationSummary conversation;
  final String activeId;

  const ConversationStateChanged({
    required this.conversation,
    required this.activeId,
  });

  factory ConversationStateChanged.fromJson(Map<String, Object?> json) =>
      ConversationStateChanged(
        conversation: ConversationSummary.fromJson(
            json['conversation'] as Map<String, Object?>),
        activeId: json['active_id'] as String,
      );

  @override
  String get frameType => 'conversation_state_changed';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conversation': conversation.toJson(), 'active_id': activeId};
}

final class ConversationRemoved extends ServerPayload {
  final String convId;
  final String activeId;

  const ConversationRemoved({required this.convId, required this.activeId});

  factory ConversationRemoved.fromJson(Map<String, Object?> json) =>
      ConversationRemoved(
        convId: json['conv_id'] as String,
        activeId: json['active_id'] as String,
      );

  @override
  String get frameType => 'conversation_removed';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'active_id': activeId};
}

final class MessagePage extends ServerPayload {
  final String convId;
  final List<Message> messages;

  /// When `messages` is empty this echoes the requested cursor.
  final int oldestSeq;
  final bool hasOlderMessages;

  const MessagePage({
    required this.convId,
    required this.messages,
    required this.oldestSeq,
    required this.hasOlderMessages,
  });

  factory MessagePage.fromJson(Map<String, Object?> json) => MessagePage(
        convId: json['conv_id'] as String,
        messages: [
          for (final m in json['messages'] as List<Object?>)
            Message.fromJson(m as Map<String, Object?>)
        ],
        oldestSeq: json['oldest_seq'] as int,
        hasOlderMessages: json['has_older_messages'] as bool,
      );

  @override
  String get frameType => 'message_page';

  @override
  Map<String, Object?> toPayloadJson() => {
        'conv_id': convId,
        'messages': [for (final m in messages) m.toJson()],
        'oldest_seq': oldestSeq,
        'has_older_messages': hasOlderMessages,
      };
}

final class StreamChunk extends ServerPayload {
  final String convId;
  final String turnId;
  final String text;

  const StreamChunk({
    required this.convId,
    required this.turnId,
    required this.text,
  });

  factory StreamChunk.fromJson(Map<String, Object?> json) => StreamChunk(
        convId: json['conv_id'] as String,
        turnId: json['turn_id'] as String,
        text: json['text'] as String,
      );

  @override
  String get frameType => 'stream_chunk';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'turn_id': turnId, 'text': text};
}

final class StreamingStatus extends ServerPayload {
  final String convId;
  final String turnId;

  /// Free-form display string.
  final String status;

  const StreamingStatus({
    required this.convId,
    required this.turnId,
    required this.status,
  });

  factory StreamingStatus.fromJson(Map<String, Object?> json) =>
      StreamingStatus(
        convId: json['conv_id'] as String,
        turnId: json['turn_id'] as String,
        status: json['status'] as String,
      );

  @override
  String get frameType => 'streaming_status';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'turn_id': turnId, 'status': status};
}

final class StreamingEnded extends ServerPayload {
  final String convId;
  final String turnId;
  final bool cancelled;
  final String? error;
  final int proposalCount;

  const StreamingEnded({
    required this.convId,
    required this.turnId,
    required this.cancelled,
    this.error,
    required this.proposalCount,
  });

  factory StreamingEnded.fromJson(Map<String, Object?> json) => StreamingEnded(
        convId: json['conv_id'] as String,
        turnId: json['turn_id'] as String,
        cancelled: json['cancelled'] as bool,
        error: json['error'] as String?,
        proposalCount: json['proposal_count'] as int,
      );

  @override
  String get frameType => 'streaming_ended';

  @override
  Map<String, Object?> toPayloadJson() {
    final map = <String, Object?>{
      'conv_id': convId,
      'turn_id': turnId,
      'cancelled': cancelled,
    };
    _put(map, 'error', error);
    map['proposal_count'] = proposalCount;
    return map;
  }
}

final class ToolCallStarted extends ServerPayload {
  final String convId;
  final String turnId;
  final String toolName;

  const ToolCallStarted({
    required this.convId,
    required this.turnId,
    required this.toolName,
  });

  factory ToolCallStarted.fromJson(Map<String, Object?> json) =>
      ToolCallStarted(
        convId: json['conv_id'] as String,
        turnId: json['turn_id'] as String,
        toolName: json['tool_name'] as String,
      );

  @override
  String get frameType => 'tool_call_started';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'turn_id': turnId, 'tool_name': toolName};
}

final class MessageComplete extends ServerPayload {
  final String convId;
  final Message message;

  const MessageComplete({required this.convId, required this.message});

  factory MessageComplete.fromJson(Map<String, Object?> json) =>
      MessageComplete(
        convId: json['conv_id'] as String,
        message: Message.fromJson(json['message'] as Map<String, Object?>),
      );

  @override
  String get frameType => 'message_complete';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'message': message.toJson()};
}

/// `permission_request` frame — wraps the [PermissionRequest] DTO (which is
/// also embedded raw in snapshots).
final class PermissionRequestFrame extends ServerPayload {
  final PermissionRequest request;

  const PermissionRequestFrame(this.request);

  factory PermissionRequestFrame.fromJson(Map<String, Object?> json) =>
      PermissionRequestFrame(PermissionRequest.fromJson(json));

  @override
  String get frameType => 'permission_request';

  @override
  Map<String, Object?> toPayloadJson() => request.toJson();
}

final class PermissionClosed extends ServerPayload {
  final String convId;
  final String requestId;
  final PermissionOutcome outcome;
  final AnsweredBy answeredBy;

  const PermissionClosed({
    required this.convId,
    required this.requestId,
    required this.outcome,
    required this.answeredBy,
  });

  factory PermissionClosed.fromJson(Map<String, Object?> json) =>
      PermissionClosed(
        convId: json['conv_id'] as String,
        requestId: json['request_id'] as String,
        outcome: PermissionOutcome.fromWire(json['outcome'] as String),
        answeredBy: AnsweredBy.fromWire(json['answered_by'] as String),
      );

  @override
  String get frameType => 'permission_closed';

  @override
  Map<String, Object?> toPayloadJson() => {
        'conv_id': convId,
        'request_id': requestId,
        'outcome': outcome.wire,
        'answered_by': answeredBy.wire,
      };
}

enum ProposalLifecycle {
  created('proposal_created'),
  updated('proposal_updated'),
  detail('proposal_detail');

  final String frameType;
  const ProposalLifecycle(this.frameType);
}

/// Shared payload of `proposal_created` / `proposal_updated` /
/// `proposal_detail` — one shape, three lifecycle meanings.
final class ProposalEvent extends ServerPayload {
  final ProposalLifecycle lifecycle;
  final Proposal proposal;

  const ProposalEvent({required this.lifecycle, required this.proposal});

  factory ProposalEvent.fromJson(
          ProposalLifecycle lifecycle, Map<String, Object?> json) =>
      ProposalEvent(
        lifecycle: lifecycle,
        proposal: Proposal.fromJson(json['proposal'] as Map<String, Object?>),
      );

  @override
  String get frameType => lifecycle.frameType;

  @override
  Map<String, Object?> toPayloadJson() => {'proposal': proposal.toJson()};
}

final class ProposalFinalized extends ServerPayload {
  final int proposalId;
  final String path;
  final ProposalOutcome outcome;

  const ProposalFinalized({
    required this.proposalId,
    required this.path,
    required this.outcome,
  });

  factory ProposalFinalized.fromJson(Map<String, Object?> json) =>
      ProposalFinalized(
        proposalId: json['proposal_id'] as int,
        path: json['path'] as String,
        outcome: ProposalOutcome.fromWire(json['outcome'] as String),
      );

  @override
  String get frameType => 'proposal_finalized';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'proposal_id': proposalId, 'path': path, 'outcome': outcome.wire};
}

final class TokenUsageEvent extends ServerPayload {
  final String convId;
  final String turnId;
  final TokenUsage usage;

  const TokenUsageEvent({
    required this.convId,
    required this.turnId,
    required this.usage,
  });

  factory TokenUsageEvent.fromJson(Map<String, Object?> json) =>
      TokenUsageEvent(
        convId: json['conv_id'] as String,
        turnId: json['turn_id'] as String,
        usage: TokenUsage.fromJson(json['usage'] as Map<String, Object?>),
      );

  @override
  String get frameType => 'token_usage';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'turn_id': turnId, 'usage': usage.toJson()};
}

final class CostUpdate extends ServerPayload {
  final String convId;
  final String turnId;
  final double usd;

  const CostUpdate({
    required this.convId,
    required this.turnId,
    required this.usd,
  });

  factory CostUpdate.fromJson(Map<String, Object?> json) => CostUpdate(
        convId: json['conv_id'] as String,
        turnId: json['turn_id'] as String,
        usd: (json['usd'] as num).toDouble(),
      );

  @override
  String get frameType => 'cost_update';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'conv_id': convId, 'turn_id': turnId, 'usd': usd};
}

final class CommandResult extends ServerPayload {
  final String commandId;
  final CommandStatus status;
  final Object? result;

  const CommandResult({
    required this.commandId,
    required this.status,
    this.result,
  });

  factory CommandResult.fromJson(Map<String, Object?> json) => CommandResult(
        commandId: json['command_id'] as String,
        status: CommandStatus.fromWire(json['status'] as String),
        result: json['result'],
      );

  @override
  String get frameType => 'command_result';

  @override
  Map<String, Object?> toPayloadJson() {
    final map = <String, Object?>{
      'command_id': commandId,
      'status': status.wire,
    };
    _put(map, 'result', result);
    return map;
  }
}

final class CommandError extends ServerPayload {
  final String commandId;
  final ErrorCode code;

  /// Raw wire code — survives codes this client does not know.
  final String rawCode;
  final String message;

  const CommandError({
    required this.commandId,
    required this.code,
    required this.rawCode,
    required this.message,
  });

  factory CommandError.fromJson(Map<String, Object?> json) {
    final raw = json['code'] as String;
    return CommandError(
      commandId: json['command_id'] as String,
      code: ErrorCode.fromWire(raw),
      rawCode: raw,
      message: json['message'] as String,
    );
  }

  @override
  String get frameType => 'command_error';

  @override
  Map<String, Object?> toPayloadJson() =>
      {'command_id': commandId, 'code': rawCode, 'message': message};
}
