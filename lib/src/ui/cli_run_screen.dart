import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/cli_runs.dart';
import '../protocol/swarm.dart';
import '../services/cli_runs_client.dart';
import '../services/instance_store.dart';
import 'swarm_screen.dart';

/// One `gaviero-cli` run (1.11 `cli_runs`), drawn like the Swarm section:
/// the header, one row per agent, the chosen agent's output. Read-only — the
/// run is started and stopped in the terminal on the computer. Polled over
/// HTTPS from any instance of the run's machine while on screen.
class CliRunScreen extends StatefulWidget {
  final CliRunsClient client;
  final MachineRecord machine;

  /// Routes to try, in order (`CliRunsClient.originsFor`).
  final List<Uri> origins;
  final CliRunSummary summary;

  const CliRunScreen({
    super.key,
    required this.client,
    required this.machine,
    required this.origins,
    required this.summary,
  });

  @override
  State<CliRunScreen> createState() => _CliRunScreenState();
}

class _CliRunScreenState extends State<CliRunScreen>
    with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 1);

  Timer? _timer;
  final _scroll = ScrollController();

  SwarmRun? _run;
  String? _selectedId;
  DateTime _receivedAt = DateTime.now();

  /// The agent chosen on the phone; null follows the run.
  String? _agentId;
  String? _outputAgent;
  String? _token;
  List<SwarmOutputLine> _lines = const [];
  bool _truncated = false;
  bool _followOutput = true;
  bool _expanded = false;

  String? _error;
  bool _missing = false;
  bool _polling = false;
  bool _foreground = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_scrolled);
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _refresh();
  }

  void _scrolled() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    _followOutput = position.pixels >= position.maxScrollExtent - 24;
  }

  /// A finished run no longer changes: polling stops once it and the shown
  /// agent's output are read.
  bool get _settled {
    final run = _run;
    if (run == null || run.running) return false;
    return run.agents.isEmpty ||
        (_token != null && _outputAgent == (_agentId ?? _selectedId));
  }

  Future<void> _refresh() async {
    if (_polling || !_foreground || _missing || _settled) return;
    _polling = true;
    final generation = _generation;
    try {
      final read = await widget.client.read(
        widget.machine,
        widget.origins,
        widget.summary.id,
        agentId: _agentId,
        outputToken: _token,
      );
      if (!mounted || generation != _generation) return;
      final snapshot = read.snapshot;
      if (snapshot != null) {
        _apply(snapshot);
      } else {
        setState(() {
          _missing = read.missing;
          _error = switch (read.status) {
            _ when read.missing => null,
            CliRunsStatus.unauthorized => 'Pair this computer again.',
            CliRunsStatus.unsupported =>
              'Update Gaviero on this computer to see CLI runs.',
            _ => 'Cannot reach ${widget.machine.host}. Retrying…',
          };
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Unable to read this run.');
      }
    } finally {
      _polling = false;
    }
  }

  void _apply(SwarmSnapshot snapshot) {
    final output = snapshot.output;
    var grew = false;
    setState(() {
      _run = snapshot.run;
      _selectedId = snapshot.selectedId;
      _receivedAt = DateTime.now();
      _error = null;
      if (output == null) {
        _outputAgent = null;
        _token = null;
        _lines = const [];
        _truncated = false;
      } else if (!output.unchanged) {
        if (output.agentId != _outputAgent) _followOutput = true;
        grew = true;
        _outputAgent = output.agentId;
        _token = output.token;
        _lines = output.lines;
        _truncated = output.truncated;
      } else if (output.agentId != _outputAgent) {
        _token = null;
      }
    });
    if (grew && _followOutput) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _choose(String? agentId) {
    setState(() {
      _generation++;
      _polling = false;
      _agentId = agentId;
      _token = null;
      _followOutput = true;
      if (agentId != null && agentId != _outputAgent) {
        _outputAgent = agentId;
        _selectedId = agentId;
        _lines = const [];
        _truncated = false;
      }
    });
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final run = _run;
    final summary = widget.summary;
    final where = [
      if (summary.folder.isNotEmpty) summary.folder,
      widget.machine.host,
    ].join(' · ');
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              summary.script.isEmpty ? 'CLI run' : summary.script,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              where,
              key: const Key('cli-run-where'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          if (_agentId != null)
            IconButton(
              key: const Key('cli-run-follow'),
              tooltip: 'Follow the run',
              icon: const Icon(Icons.my_location),
              onPressed: () => _choose(null),
            ),
          if (run != null)
            IconButton(
              key: const Key('cli-run-expand'),
              tooltip: _expanded ? 'Show agents' : 'Expand output',
              icon: Icon(_expanded ? Icons.fullscreen_exit : Icons.fullscreen),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!, key: const Key('cli-run-error')),
              ),
            Expanded(child: _body(run)),
          ],
        ),
      ),
    );
  }

  Widget _body(SwarmRun? run) {
    if (_missing) {
      return const SwarmNotice(
        'This run is no longer on the computer (only the newest 20 are kept).',
      );
    }
    if (run == null) return const SwarmNotice('Reading the run…');
    return SwarmRunView(
      run: run,
      selectedId: _selectedId,
      receivedAt: _receivedAt,
      expanded: _expanded,
      outputAgent: _outputAgent,
      hasOutput: _token != null,
      lines: _lines,
      truncated: _truncated,
      scroll: _scroll,
      onChoose: _choose,
      followLabel: _agentId == null && run.running ? 'following the run' : null,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    super.dispose();
  }
}
