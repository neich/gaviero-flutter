/// `GET /v1/cli-runs` body (1.11, `cli_runs`) — the machine's `gaviero-cli`
/// runs. One run (`GET /v1/cli-runs/<id>`) decodes as a [SwarmSnapshot]
/// (`swarm.dart`): the same shape as the `request_swarm` reply. These
/// decoders are the client's contract with PROTOCOL.md §CLI runs.
library;

import 'swarm.dart';

enum CliRunState {
  running,
  completed,
  completedWithFailures,
  failed,
  interrupted;

  /// Unknown values read as failed: a newer server's ending is shown as
  /// "ended" rather than failing the whole list.
  static CliRunState parse(Object? value) => switch (value) {
    'running' => running,
    'completed' => completed,
    'completed_with_failures' => completedWithFailures,
    'interrupted' => interrupted,
    _ => failed,
  };

  String get label => switch (this) {
    running => 'running',
    completed => 'completed',
    completedWithFailures => 'completed with failures',
    failed => 'failed',
    interrupted => 'interrupted',
  };
}

/// One row of the list.
final class CliRunSummary {
  final String id;

  /// Script file name without extension (`task` / `work units` for those
  /// modes), plus ` · <workflow>` when one was chosen.
  final String script;

  /// Name of the folder the run ran in — never a path.
  final String folder;
  final CliRunState state;

  /// The pipeline's display string while running.
  final String phase;
  final DateTime? startedAt;
  final DateTime? updatedAt;
  final double costUsd;
  final SwarmCounts counts;
  final int agentCount;

  const CliRunSummary({
    required this.id,
    required this.script,
    this.folder = '',
    required this.state,
    this.phase = '',
    this.startedAt,
    this.updatedAt,
    this.costUsd = 0,
    this.counts = const SwarmCounts(),
    this.agentCount = 0,
  });

  bool get running => state == CliRunState.running;

  factory CliRunSummary.fromJson(Map<String, Object?> json) => CliRunSummary(
    id: json['id'] as String,
    script: json['script'] as String? ?? '',
    folder: json['folder'] as String? ?? '',
    state: CliRunState.parse(json['state']),
    phase: json['phase'] as String? ?? '',
    startedAt: _time(json['started_at']),
    updatedAt: _time(json['updated_at']),
    costUsd: (json['cost_usd'] as num?)?.toDouble() ?? 0,
    counts: SwarmCounts.fromJson(json['counts'] as Map<String, Object?>?),
    agentCount: json['agents'] as int? ?? 0,
  );
}

final class CliRunList {
  final String host;
  final List<CliRunSummary> runs;

  const CliRunList({required this.host, this.runs = const []});

  factory CliRunList.fromJson(Map<String, Object?> json) => CliRunList(
    host: json['host'] as String? ?? '',
    runs: [
      for (final r in (json['runs'] as List?) ?? const [])
        CliRunSummary.fromJson(r as Map<String, Object?>),
    ],
  );
}

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;
