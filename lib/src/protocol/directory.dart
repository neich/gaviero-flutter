/// `GET /v1/instances` body (1.1) — the machine instance directory. Never
/// carries an absolute path, a token, or conversation content.
library;

import 'dto.dart';
import 'version.dart';

final class InstanceInfo {
  final String instanceId;
  final WorkspaceInfo workspace;

  /// `wss://<host>:<port>/v1/ws`
  final String url;
  final int port;
  final String tuiVersion;

  /// RFC 3339.
  final String startedAt;

  /// A mobile client is currently attached; connecting will replace it.
  final bool clientConnected;

  const InstanceInfo({
    required this.instanceId,
    required this.workspace,
    required this.url,
    required this.port,
    required this.tuiVersion,
    required this.startedAt,
    required this.clientConnected,
  });

  factory InstanceInfo.fromJson(Map<String, Object?> json) => InstanceInfo(
        instanceId: json['instance_id'] as String,
        workspace:
            WorkspaceInfo.fromJson(json['workspace'] as Map<String, Object?>),
        url: json['url'] as String,
        port: json['port'] as int,
        tuiVersion: json['tui_version'] as String,
        startedAt: json['started_at'] as String,
        clientConnected: json['client_connected'] as bool,
      );

  Map<String, Object?> toJson() => {
        'instance_id': instanceId,
        'workspace': workspace.toJson(),
        'url': url,
        'port': port,
        'tui_version': tuiVersion,
        'started_at': startedAt,
        'client_connected': clientConnected,
      };
}

/// Only instances with a fresh heartbeat are listed, so "listed" means
/// "running".
final class InstanceDirectory {
  final ProtocolVersion protocolVersion;
  final String host;

  /// RFC 3339.
  final String generatedAt;
  final List<InstanceInfo> instances;

  const InstanceDirectory({
    required this.protocolVersion,
    required this.host,
    required this.generatedAt,
    required this.instances,
  });

  factory InstanceDirectory.fromJson(Map<String, Object?> json) =>
      InstanceDirectory(
        protocolVersion: ProtocolVersion.fromJson(
            json['protocol_version'] as Map<String, Object?>),
        host: json['host'] as String,
        generatedAt: json['generated_at'] as String,
        instances: [
          for (final i in json['instances'] as List<Object?>)
            InstanceInfo.fromJson(i as Map<String, Object?>)
        ],
      );

  Map<String, Object?> toJson() => {
        'protocol_version': protocolVersion.toJson(),
        'host': host,
        'generated_at': generatedAt,
        'instances': [for (final i in instances) i.toJson()],
      };
}
