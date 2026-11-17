import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/client_frames.dart';
import '../protocol/swarm.dart';
import '../protocol/version.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import 'chat_screen.dart';
import 'theme.dart';

/// Mirrors the desktop SWARM panel (`Alt+W`): the run's header, one row per
/// agent with its state, and the chosen agent's output. Read-only — scripts
/// are started and stopped on the computer. Choosing an agent here never
/// moves the desktop's selection; until one is chosen the screen follows the
/// desktop's (which follows whichever agent started last).
class SwarmScreen extends StatefulWidget {
  final RemoteController controller;
  const SwarmScreen({super.key, required this.controller});

  @override
  State<SwarmScreen> createState() => _SwarmScreenState();
}

class _SwarmScreenState extends State<SwarmScreen> with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 1);

  Timer? _timer;
  final _scroll = ScrollController();

  SwarmRun? _run;
  String? _selectedId;
  DateTime _receivedAt = DateTime.now();

  /// The agent chosen on the phone; null follows the desktop's selection.
  String? _agentId;

  /// Output on screen: whose, its token, and its lines.
  String? _outputAgent;
  String? _token;
  List<SwarmOutputLine> _lines = const [];
  bool _truncated = false;

  /// Keep the output scrolled to its end until the user scrolls up.
  bool _followOutput = true;

  /// The output fills the screen; the agent list is hidden.
  bool _expanded = false;

  String? _error;
  bool _fresh = false;
  bool _polling = false;
  bool _foreground = true;

  /// False while another home section is showing: polling pauses.
  bool? _visible;
  int _generation = 0;

  RemoteConnection get _connection => widget.controller.connection;
  bool get _supported =>
      _connection.hello?.capabilities.contains(Capability.swarmActivity) ??
      false;
  bool get _connected => _connection.phase == ConnectionPhase.connected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connection.addListener(_connectionChanged);
    _scroll.addListener(_scrolled);
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The home screen keeps every section mounted (IndexedStack, which
    // reports through Visibility.of); a hidden swarm screen stops polling and
    // catches up the moment it shows again.
    final visible = Visibility.of(context);
    if (visible != _visible) {
      _visible = visible;
      if (visible) _refresh();
    }
  }

  void _connectionChanged() {
    if (!mounted) return;
    if (!_connected) {
      // Another instance (or a reconnect) may run a different swarm: the
      // output is fetched again in full.
      _generation++;
      _fresh = false;
      _token = null;
    }
    setState(() {});
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

  Future<void> _refresh() async {
    if (_polling ||
        !_foreground ||
        _visible == false ||
        !_connected ||
        !_supported) {
      return;
    }
    _polling = true;
    final generation = _generation;
    final instanceId = _connection.instanceId;
    try {
      final outcome = await _connection.send(
        RequestSwarm(agentId: _agentId, outputToken: _token),
      );
      if (!mounted ||
          generation != _generation ||
          instanceId != _connection.instanceId) {
        return;
      }
      if (outcome is CommandOk) {
        _apply(SwarmSnapshot.fromJson(
          outcome.result.result as Map<String, Object?>,
        ));
      } else {
        setState(() {
          _fresh = false;
          _error = outcome is CommandFail
              ? outcome.error.message
              : 'Connection lost. Reconnecting…';
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _fresh = false;
          _error = 'Unable to read swarm activity.';
        });
      }
    } finally {
      _polling = false;
    }
  }

  void _apply(SwarmSnapshot snapshot) {
    final run = snapshot.run;
    final output = snapshot.output;
    var grew = false;
    setState(() {
      // A new run: the agent chosen in the old one is gone.
      if (run?.runId != _run?.runId) _agentId = null;
      _run = run;
      _selectedId = snapshot.selectedId;
      _receivedAt = DateTime.now();
      _fresh = true;
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
        // Not ours to keep: ask for this agent's lines in full next time.
        _token = null;
      }
    });
    if (grew && _followOutput) _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _choose(String? agentId) {
    setState(() {
      _generation++;
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
    final instanceName = widget.controller.current?.displayName;
    final run = _run;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          instanceName == null || instanceName.isEmpty
              ? 'Swarm'
              : 'Swarm · $instanceName',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_agentId != null)
            IconButton(
              key: const Key('swarm-follow-desktop'),
              tooltip: "Follow the computer's selection",
              icon: const Icon(Icons.my_location),
              onPressed: () => _choose(null),
            ),
          if (run != null)
            IconButton(
              key: const Key('swarm-expand'),
              tooltip: _expanded ? 'Show agents' : 'Expand output',
              icon: Icon(_expanded ? Icons.fullscreen_exit : Icons.fullscreen),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            ConnectionBanner(
              connection: _connection,
              instanceName: instanceName,
            ),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
            Expanded(child: _body(context, run)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, SwarmRun? run) {
    if (_connected && !_supported) {
      return const _Notice(
        'Update Gaviero on this computer to see swarm activity.',
      );
    }
    if (run == null) {
      return _Notice(
        _fresh
            ? 'No swarm has run in this Gaviero yet. Start a script from the '
                  'SWARM panel (Alt+W) on the computer.'
            : 'Waiting for swarm activity…',
      );
    }
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
      followLabel: _agentId == null ? 'following the computer' : null,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connection.removeListener(_connectionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    super.dispose();
  }
}

/// A run as the Swarm section draws it: the header, one row per agent
/// (hidden when [expanded]), whose output is shown, and that output. Shared
/// by the Swarm section and a CLI run; the owner polls and keeps the state.
class SwarmRunView extends StatelessWidget {
  final SwarmRun run;
  final String? selectedId;

  /// When [run] arrived: running agents' times tick on from it.
  final DateTime receivedAt;
  final bool expanded;

  /// Whose output [lines] are, and whether any reply carried it yet.
  final String? outputAgent;
  final bool hasOutput;
  final List<SwarmOutputLine> lines;
  final bool truncated;
  final ScrollController scroll;
  final void Function(String agentId) onChoose;

  /// Shown beside the output's agent while the screen follows the run's
  /// own choice; null once the user picked one.
  final String? followLabel;

  const SwarmRunView({
    super.key,
    required this.run,
    required this.selectedId,
    required this.receivedAt,
    required this.expanded,
    required this.outputAgent,
    required this.hasOutput,
    required this.lines,
    required this.truncated,
    required this.scroll,
    required this.onChoose,
    this.followLabel,
  });

  /// The agent's run time now: the reply's, ticking on for a running agent.
  Duration? _elapsed(SwarmAgent agent) {
    final elapsed = agent.elapsed;
    if (elapsed == null || agent.status != SwarmAgentStatus.running) {
      return elapsed;
    }
    return elapsed + DateTime.now().difference(receivedAt);
  }

  SwarmAgent? get _selectedAgent {
    for (final agent in run.agents) {
      if (agent.id == selectedId) return agent;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RunHeader(run: run),
          if (!expanded && run.agents.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * 0.4,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final agent in run.agents)
                    _AgentRow(
                      agent: agent,
                      elapsed: _elapsed(agent),
                      selected: agent.id == selectedId,
                      onTap: () => onChoose(agent.id),
                    ),
                ],
              ),
            ),
          _OutputHeader(agent: _selectedAgent, followLabel: followLabel),
          Expanded(child: _output(context)),
        ],
      ),
    );
  }

  Widget _output(BuildContext context) {
    final agent = _selectedAgent;
    final scheme = Theme.of(context).colorScheme;
    if (agent == null) {
      return const _Notice('No agent selected.');
    }
    if (lines.isEmpty) {
      return _Notice(
        agent.status == SwarmAgentStatus.queued
            ? 'Queued. Output appears when it starts.'
            : outputAgent == agent.id && hasOutput
            ? 'No output.'
            : 'Waiting for output…',
      );
    }
    final spans = <TextSpan>[
      if (truncated)
        TextSpan(
          text: 'Earlier output is not shown.\n',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      for (final (i, line) in lines.indexed)
        TextSpan(
          text: i == lines.length - 1 ? line.text : '${line.text}\n',
          style: _lineStyle(line.kind, scheme),
        ),
    ];
    return Container(
      color: codeBackground,
      width: double.infinity,
      child: SingleChildScrollView(
        key: const Key('swarm-output'),
        controller: scroll,
        padding: const EdgeInsets.all(12),
        child: SelectableText.rich(
          TextSpan(
            style: const TextStyle(fontSize: 13, height: 1.35),
            children: spans,
          ),
        ),
      ),
    );
  }

  static TextStyle _lineStyle(SwarmLineKind kind, ColorScheme scheme) =>
      switch (kind) {
        SwarmLineKind.text => TextStyle(color: scheme.onSurface),
        SwarmLineKind.toolCall => TextStyle(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontFamily: codeFontFamily,
        ),
        SwarmLineKind.status => const TextStyle(color: Color(0xFF80CBC4)),
        SwarmLineKind.fileChange => const TextStyle(
          color: Color(0xFFC3E88D),
          fontFamily: codeFontFamily,
        ),
      };
}

/// A centred line of text in place of a run.
class SwarmNotice extends StatelessWidget {
  final String text;
  const SwarmNotice(this.text, {super.key});

  @override
  Widget build(BuildContext context) => _Notice(text);
}

/// `12s`, `3m4s`, `1h2m` — the desktop table's format.
String formatElapsed(Duration? elapsed) {
  if (elapsed == null) return '';
  final secs = elapsed.inSeconds;
  if (secs < 60) return '${secs}s';
  if (secs < 3600) return '${secs ~/ 60}m${secs % 60}s';
  return '${secs ~/ 3600}h${(secs % 3600) ~/ 60}m';
}

class _Notice extends StatelessWidget {
  final String text;
  const _Notice(this.text);

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}

class _RunHeader extends StatelessWidget {
  final SwarmRun run;
  const _RunHeader({required this.run});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    final phaseColor = run.failed
        ? scheme.error
        : run.running
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final counts = run.counts;
    Widget count(IconData icon, int n, String label, Color color) => Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: n > 0 ? color : scheme.outline),
          const SizedBox(width: 4),
          Text(
            '$n $label',
            style: TextStyle(
              fontSize: 12,
              color: n > 0 ? color : scheme.outline,
              fontWeight: n > 0 ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
    return Material(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    run.script,
                    key: const Key('swarm-script'),
                    style: theme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  run.phase,
                  key: const Key('swarm-phase'),
                  style: TextStyle(color: phaseColor, fontSize: 13),
                ),
                const Spacer(),
                if (run.tierTotal > 0)
                  Text(
                    'Tier ${run.tierCurrent}/${run.tierTotal}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (run.costUsd > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '~\$${run.costUsd.toStringAsFixed(3)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              children: [
                count(Icons.circle, counts.running, 'running', scheme.primary),
                count(
                  Icons.radio_button_unchecked,
                  counts.queued,
                  'queued',
                  scheme.onSurfaceVariant,
                ),
                count(Icons.check, counts.done, 'done', Colors.green),
                count(Icons.close, counts.failed, 'failed', scheme.error),
              ],
            ),
            if (run.message.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                run.message,
                key: const Key('swarm-message'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: run.failed ? scheme.error : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  final SwarmAgent agent;
  final Duration? elapsed;
  final bool selected;
  final VoidCallback onTap;

  const _AgentRow({
    required this.agent,
    required this.elapsed,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = agent.status == SwarmAgentStatus.running;
    final Widget icon = switch (agent.status) {
      SwarmAgentStatus.queued => Icon(
        Icons.radio_button_unchecked,
        size: 16,
        color: scheme.outline,
      ),
      SwarmAgentStatus.running => SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: scheme.primary,
        ),
      ),
      SwarmAgentStatus.completed => const Icon(
        Icons.check,
        size: 16,
        color: Colors.green,
      ),
      SwarmAgentStatus.failed => Icon(Icons.close, size: 16, color: scheme.error),
    };
    final detail = agent.detail.isNotEmpty
        ? agent.detail
        : agent.error ?? '';
    final tier = switch (agent.tier) {
      'cheap' => ('C', scheme.onSurfaceVariant),
      'expensive' => ('E', Colors.amber),
      _ => null,
    };
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        key: Key('swarm-agent-${agent.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              SizedBox(width: 18, child: Center(child: icon)),
              const SizedBox(width: 8),
              if (tier != null) ...[
                Text(
                  tier.$1,
                  style: TextStyle(
                    color: tier.$2,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                flex: 2,
                child: Text(
                  agent.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: running ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: agent.status == SwarmAgentStatus.failed
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatElapsed(elapsed),
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The divider above the output: whose it is, where it ran, and — once the
/// run finished — its branch and the files it changed.
class _OutputHeader extends StatelessWidget {
  final SwarmAgent? agent;
  final String? followLabel;

  const _OutputHeader({required this.agent, required this.followLabel});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agent = this.agent;
    final label = agent == null
        ? 'No agent'
        : [agent.id, ?agent.backend].join(' · ');
    final files = agent?.modifiedFiles ?? const <String>[];
    final branch = agent?.branch;
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    key: const Key('swarm-output-agent'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (followLabel != null)
                  Text(
                    followLabel!,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
              ],
            ),
            if (branch != null || files.isNotEmpty)
              Text(
                [
                  if (branch != null) 'Branch $branch',
                  if (files.isNotEmpty)
                    '${files.length} file${files.length == 1 ? '' : 's'}: '
                        '${files.join(', ')}',
                ].join(' · '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}
