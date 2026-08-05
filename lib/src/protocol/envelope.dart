/// Wire envelopes (PROTOCOL.md §Envelopes).
library;

import 'dart:convert';

import 'client_frames.dart';
import 'server_frames.dart';
import 'version.dart';

/// Client → server. `instance_id` is always present on the wire: literal
/// `null` exactly on `client_hello` (the only frame sent before the server's
/// `hello` delivers the id), the echoed id on every later frame.
final class ClientEnvelope {
  final ProtocolVersion version;
  final String? instanceId;
  final String commandId;
  final ClientPayload payload;

  const ClientEnvelope({
    this.version = protocolVersion,
    required this.instanceId,
    required this.commandId,
    required this.payload,
  });

  factory ClientEnvelope.fromJson(Map<String, Object?> json) => ClientEnvelope(
        version:
            ProtocolVersion.fromJson(json['version'] as Map<String, Object?>),
        instanceId: json['instance_id'] as String?,
        commandId: json['command_id'] as String,
        payload: ClientPayload.fromJson(
          json['type'] as String,
          json['payload'] as Map<String, Object?>? ?? const {},
        ),
      );

  Map<String, Object?> toJson() => {
        'version': version.toJson(),
        'instance_id': instanceId,
        'command_id': commandId,
        'type': payload.frameType,
        'payload': payload.toPayloadJson(),
      };

  String encode() => jsonEncode(toJson());
}

/// Server → client.
final class ServerEnvelope {
  final ProtocolVersion version;
  final String instanceId;

  /// Monotonic per `instance_id`, continues across socket generations.
  /// A gap ⇒ `request_snapshot`.
  final int seq;

  /// Global snapshot generation. Staleness display only — never sent back
  /// as a command precondition.
  final int revision;
  final ServerPayload payload;

  const ServerEnvelope({
    required this.version,
    required this.instanceId,
    required this.seq,
    required this.revision,
    required this.payload,
  });

  factory ServerEnvelope.fromJson(Map<String, Object?> json) => ServerEnvelope(
        version:
            ProtocolVersion.fromJson(json['version'] as Map<String, Object?>),
        instanceId: json['instance_id'] as String,
        seq: json['seq'] as int,
        revision: json['revision'] as int,
        payload: ServerPayload.fromJson(
          json['type'] as String,
          json['payload'] as Map<String, Object?>? ?? const {},
        ),
      );

  /// Decodes one text frame. Throws [FormatException] on malformed JSON or a
  /// shape violation; an unknown frame *type* is NOT an error (the payload
  /// comes back as [UnknownServerPayload]).
  static ServerEnvelope decode(String text) =>
      ServerEnvelope.fromJson(jsonDecode(text) as Map<String, Object?>);

  Map<String, Object?> toJson() => {
        'version': version.toJson(),
        'instance_id': instanceId,
        'seq': seq,
        'revision': revision,
        'type': payload.frameType,
        'payload': payload.toPayloadJson(),
      };

  String encode() => jsonEncode(toJson());
}
