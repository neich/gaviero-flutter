/// Result payload of the 1.10 `request_swarm` command. `command_result.result`
/// is untyped on the wire; these decoders are the client's contract with
/// PROTOCOL.md §Swarm activity.
library;

enum SwarmAgentStatus {
  queued,
  running,
  completed,
  failed;

  /// Unknown values read as queued: a newer server's state is shown as
  /// "not started" rather than failing the whole reply.
  static SwarmAgentStatus parse(Object? value) => switch (value) {
    'running' => running,
    'completed' => completed,
    'failed' => failed,
    _ => queued,
  };
}

final class SwarmAgent {
  final String id;
  final SwarmAgentStatus status;

  /// Why the agent failed, when [status] is failed.
  final String? error;

  /// The desktop table row's latest one-liner.
  final String detail;

  /// `cheap` / `expensive`, or null when unknown.
  final String? tier;

  /// `provider:model` it was dispatched to, once known.
  final String? backend;

  /// Run time at reply time; null before it started.
  final Duration? elapsed;
  final String? branch;
  final List<String> modifiedFiles;

  const SwarmAgent({
    required this.id,
    required this.status,
    this.error,
    this.detail = '',
    this.tier,
    this.backend,
    this.elapsed,
    this.branch,
    this.modifiedFiles = const [],
  });

  factory SwarmAgent.fromJson(Map<String, Object?> json) {
    final ms = json['elapsed_ms'] as int?;
    return SwarmAgent(
      id: json['id'] as String,
      status: SwarmAgentStatus.parse(json['status']),
      error: json['error'] as String?,
      detail: json['detail'] as String? ?? '',
      tier: json['tier'] as String?,
      backend: json['backend'] as String?,
      elapsed: ms == null ? null : Duration(milliseconds: ms),
      branch: json['branch'] as String?,
      modifiedFiles: [
        for (final f in (json['modified_files'] as List?) ?? const [])
          f as String,
      ],
    );
  }
}

final class SwarmCounts {
  final int running;
  final int queued;
  final int done;
  final int failed;

  const SwarmCounts({
    this.running = 0,
    this.queued = 0,
    this.done = 0,
    this.failed = 0,
  });

  factory SwarmCounts.fromJson(Map<String, Object?>? json) => SwarmCounts(
    running: json?['running'] as int? ?? 0,
    queued: json?['queued'] as int? ?? 0,
    done: json?['done'] as int? ?? 0,
    failed: json?['failed'] as int? ?? 0,
  );
}

/// The desktop SWARM panel's run: its header and one row per agent.
final class SwarmRun {
  final int runId;
  final String script;

  /// The desktop's display string (`starting`, a pipeline phase,
  /// `completed`, `completed with failures`, `failed`, `stopped`, …).
  final String phase;
  final bool running;
  final int tierCurrent;
  final int tierTotal;
  final double costUsd;

  /// Run-wide note under the header (preparation notes, the failure).
  final String message;
  final SwarmCounts counts;
  final List<SwarmAgent> agents;

  /// 1.11, CLI runs only: the run's id, the folder it ran in, its state
  /// (`running`, `interrupted`, …) and start time.
  final String? id;
  final String? folder;
  final String? state;
  final DateTime? startedAt;

  const SwarmRun({
    required this.runId,
    required this.script,
    required this.phase,
    required this.running,
    this.tierCurrent = 0,
    this.tierTotal = 0,
    this.costUsd = 0,
    this.message = '',
    this.counts = const SwarmCounts(),
    this.agents = const [],
    this.id,
    this.folder,
    this.state,
    this.startedAt,
  });

  factory SwarmRun.fromJson(Map<String, Object?> json) => SwarmRun(
    runId: json['run_id'] as int,
    script: json['script'] as String? ?? '',
    phase: json['phase'] as String? ?? '',
    running: json['running'] as bool? ?? false,
    tierCurrent: json['tier_current'] as int? ?? 0,
    tierTotal: json['tier_total'] as int? ?? 0,
    costUsd: (json['cost_usd'] as num?)?.toDouble() ?? 0,
    message: json['message'] as String? ?? '',
    counts: SwarmCounts.fromJson(json['counts'] as Map<String, Object?>?),
    agents: [
      for (final a in (json['agents'] as List?) ?? const [])
        SwarmAgent.fromJson(a as Map<String, Object?>),
    ],
    id: json['id'] as String?,
    folder: json['folder'] as String?,
    state: json['state'] as String?,
    startedAt: json['started_at'] is String
        ? DateTime.tryParse(json['started_at'] as String)?.toUtc()
        : null,
  );

  bool get failed => phase == 'failed' || phase == 'interrupted';
}

enum SwarmLineKind {
  text,
  toolCall,
  status,
  fileChange;

  static SwarmLineKind parse(Object? value) => switch (value) {
    'tool_call' => toolCall,
    'status' => status,
    'file_change' => fileChange,
    _ => text,
  };
}

final class SwarmOutputLine {
  final SwarmLineKind kind;
  final String text;

  const SwarmOutputLine(this.kind, this.text);

  factory SwarmOutputLine.fromJson(Map<String, Object?> json) =>
      SwarmOutputLine(
        SwarmLineKind.parse(json['kind']),
        json['text'] as String? ?? '',
      );
}

/// One agent's output. When [unchanged], [lines] is empty and the client
/// keeps what it has for [token].
final class SwarmOutput {
  final String agentId;
  final String token;
  final bool unchanged;
  final List<SwarmOutputLine> lines;

  /// Older output was left out (the reply carries at most 64 KiB).
  final bool truncated;

  const SwarmOutput({
    required this.agentId,
    required this.token,
    this.unchanged = false,
    this.lines = const [],
    this.truncated = false,
  });

  factory SwarmOutput.fromJson(Map<String, Object?> json) => SwarmOutput(
    agentId: json['agent_id'] as String,
    token: json['token'] as String,
    unchanged: json['unchanged'] as bool? ?? false,
    lines: [
      for (final l in (json['lines'] as List?) ?? const [])
        SwarmOutputLine.fromJson(l as Map<String, Object?>),
    ],
    truncated: json['truncated'] as bool? ?? false,
  );
}

final class SwarmSnapshot {
  /// Null when no script has run since the desktop started.
  final SwarmRun? run;
  final String? selectedId;
  final SwarmOutput? output;

  const SwarmSnapshot({this.run, this.selectedId, this.output});

  factory SwarmSnapshot.fromJson(Map<String, Object?> json) {
    final run = json['run'] as Map<String, Object?>?;
    final output = json['output'] as Map<String, Object?>?;
    return SwarmSnapshot(
      run: run == null ? null : SwarmRun.fromJson(run),
      selectedId: json['selected_id'] as String?,
      output: output == null ? null : SwarmOutput.fromJson(output),
    );
  }
}
