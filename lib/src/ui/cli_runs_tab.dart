/// The instance picker's **CLI runs** tab: every paired machine's
/// `gaviero-cli` runs (1.11 `cli_runs`), running ones first, then newest.
/// Polled while shown; tap opens the run like the Swarm section.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/cli_runs.dart';
import '../services/cli_runs_client.dart';
import '../services/instance_store.dart';
import '../state/hub.dart';
import 'cli_run_screen.dart';
import 'swarm_screen.dart' show formatElapsed;

/// Display order: running first, then by start time, newest first. Stable.
List<(MachineRecord, CliRunSummary)> orderCliRuns(
  List<MachineCliRuns> machines,
) {
  final rows = [
    for (final m in machines)
      for (final run in m.runs) (m.machine, run),
  ];
  final indexed = [for (var i = 0; i < rows.length; i++) (i, rows[i])];
  indexed.sort((a, b) {
    final ar = a.$2.$2, br = b.$2.$2;
    if (ar.running != br.running) return ar.running ? -1 : 1;
    final at = ar.startedAt, bt = br.startedAt;
    if (at != null && bt != null && at != bt) return bt.compareTo(at);
    return a.$1.compareTo(b.$1);
  });
  return [for (final (_, row) in indexed) row];
}

/// `14:05` today, `2026-11-16 14:05` otherwise, in local time.
String formatRunTime(DateTime? at, {DateTime? now}) {
  if (at == null) return '';
  final local = at.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  if (local.year == today.year &&
      local.month == today.month &&
      local.day == today.day) {
    return time;
  }
  return '${local.year}-${two(local.month)}-${two(local.day)} $time';
}

class CliRunsTab extends StatefulWidget {
  final RemoteHub controller;

  const CliRunsTab({super.key, required this.controller});

  @override
  State<CliRunsTab> createState() => _CliRunsTabState();
}

class _CliRunsTabState extends State<CliRunsTab> with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 3);

  Timer? _timer;
  List<MachineCliRuns>? _machines;
  bool _loading = false;
  bool _foreground = true;

  /// False while a run is open on top: the list waits until it is back.
  bool _covered = false;

  RemoteHub get _hub => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
    // `_refresh` reads the route, which initState may not.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _refresh();
  }

  Future<void> _refresh() async {
    // Another screen on top (a run, the scanner, pairing): wait for it.
    if (!mounted) return;
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    if (_loading || !_foreground || _covered || !onTop) return;
    _loading = true;
    try {
      final machines = await _hub.cliRunsClient.list(_hub.instanceStore);
      if (mounted) setState(() => _machines = machines);
    } finally {
      _loading = false;
    }
  }

  Future<void> _open(MachineRecord machine, CliRunSummary run) async {
    _covered = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => CliRunScreen(
          client: _hub.cliRunsClient,
          machine: machine,
          origins: CliRunsClient.originsFor(
            machine,
            _hub.instanceStore.doc.instances,
          ),
          summary: run,
        ),
      ),
    );
    _covered = false;
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final machines = _machines;
    final rows = machines == null ? const <(MachineRecord, CliRunSummary)>[] : orderCliRuns(machines);
    final notes = [
      for (final m in machines ?? const <MachineCliRuns>[])
        if (_note(m) case final note?) (m.machine.host, note),
    ];
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const Key('cli-runs-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (machines == null) const LinearProgressIndicator(minHeight: 2),
          for (final (machine, run) in rows)
            _CliRunRow(
              machine: machine,
              run: run,
              onTap: () => _open(machine, run),
            ),
          if (machines != null && rows.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
              child: Text(
                'No gaviero-cli runs. A run started with gaviero-cli on a '
                'paired computer shows here while Gaviero is open there.',
                key: Key('cli-runs-empty'),
              ),
            ),
          for (final (host, note) in notes)
            ListTile(
              key: ValueKey('cli-runs-note-$host'),
              dense: true,
              leading: const Icon(Icons.info_outline, size: 18),
              title: Text(host),
              subtitle: Text(note),
            ),
        ],
      ),
    );
  }

  static String? _note(MachineCliRuns m) => switch (m.status) {
    CliRunsStatus.ok => null,
    CliRunsStatus.unsupported =>
      'Update Gaviero on this computer to see its CLI runs.',
    CliRunsStatus.unauthorized => 'Pair this computer again.',
    CliRunsStatus.unreachable =>
      'Not reachable — CLI runs show while Gaviero is open on it.',
  };

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _CliRunRow extends StatelessWidget {
  final MachineRecord machine;
  final CliRunSummary run;
  final VoidCallback onTap;

  const _CliRunRow({
    required this.machine,
    required this.run,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget icon = switch (run.state) {
      CliRunState.running => SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
      ),
      CliRunState.completed => const Icon(Icons.check, color: Colors.green),
      CliRunState.completedWithFailures => const Icon(
        Icons.warning_amber,
        color: Colors.amber,
      ),
      CliRunState.interrupted => Icon(Icons.link_off, color: scheme.outline),
      CliRunState.failed => Icon(Icons.close, color: scheme.error),
    };
    final counts = run.counts;
    final started = formatRunTime(run.startedAt);
    final runningFor = run.running && run.startedAt != null
        ? formatElapsed(DateTime.now().toUtc().difference(run.startedAt!))
        : null;
    final tally = [
      if (counts.running > 0) '${counts.running} running',
      if (counts.queued > 0) '${counts.queued} queued',
      if (counts.done > 0) '${counts.done} done',
      if (counts.failed > 0) '${counts.failed} failed',
    ].join(', ');
    return ListTile(
      key: ValueKey('cli-run-${run.id}'),
      leading: SizedBox(width: 24, child: Center(child: icon)),
      title: Text(
        run.script.isEmpty ? 'CLI run' : run.script,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.computer, size: 14),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  [
                    if (run.folder.isNotEmpty) run.folder,
                    machine.host,
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Text(
            [
              run.running && run.phase.isNotEmpty ? run.phase : run.state.label,
              if (started.isNotEmpty) 'started $started',
              ?runningFor,
              if (tally.isNotEmpty) tally,
            ].join(' · '),
            key: ValueKey('cli-run-status-${run.id}'),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
