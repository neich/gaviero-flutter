import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/client_frames.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import 'chat_screen.dart';
import 'shell_paths.dart';

/// Mirrors the existing desktop PTYs. Input is never replayed on reconnect.
class ShellScreen extends StatefulWidget {
  final RemoteController controller;
  const ShellScreen({super.key, required this.controller});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _drafts = <int, String>{};
  /// Per tab, commands sent from this screen, oldest first: the recall list
  /// for servers without `shell_history`.
  final _sent = <int, List<String>>{};
  /// The list ↑/↓ walk, captured when a recall starts: the tab's own shell
  /// history from the server, or [_sent]. Only single-line entries — the box
  /// is one line.
  List<String> _recallList = const [];
  /// Position in [_recallList] while recalling, or null on the live line.
  int? _recallAt;
  /// The line being typed when recall started, restored past the newest entry.
  String _liveLine = '';
  bool _loadingHistory = false;
  Timer? _timer;
  List<Map<String, Object?>> _tabs = [];
  int? _selected;
  String _output = '';
  /// Workspace roots from the server; empty from servers that omit them.
  ShellPaths _paths = ShellPaths(const []);
  String _rootsKey = '';
  /// Show prompt and output paths relative to the workspace roots.
  bool _shortPaths = true;
  String? _error;
  bool _polling = false;
  bool _sending = false;
  bool _fresh = false;
  bool _foreground = true;
  int _generation = 0;

  RemoteConnection get _connection => widget.controller.connection;
  bool get _supported =>
      _connection.hello?.capabilities.contains('shell_sessions') ?? false;
  bool get _serverHistory =>
      _connection.hello?.capabilities.contains('shell_history') ?? false;
  bool get _connected => _connection.phase == ConnectionPhase.connected;
  bool get _fieldEnabled =>
      _connected && _supported && _fresh && _selected != null;
  bool get _canInput => _fieldEnabled && !_sending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connection.addListener(_connectionChanged);
    _timer = Timer.periodic(const Duration(milliseconds: 750), (_) => _refresh());
    _refresh();
  }

  void _connectionChanged() {
    if (!mounted) return;
    if (!_connected) {
      _generation++;
      _tabs = [];
      _selected = null;
      _output = '';
      _fresh = false;
      _drafts.clear();
      _input.clear();
      _resetRecall();
    }
    setState(() {});
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _refresh();
  }

  Future<void> _refresh() async {
    if (_polling || !_foreground || !_connected || !_supported) return;
    _polling = true;
    final generation = _generation;
    final instanceId = _connection.instanceId;
    try {
      final outcome = await _connection.send(RequestTerminals(terminalId: _selected));
      if (!mounted || generation != _generation ||
          instanceId != _connection.instanceId) {
        return;
      }
      if (outcome is CommandOk) {
        final result = outcome.result.result as Map<String, Object?>;
        final tabs = (result['terminals'] as List)
            .cast<Map<String, Object?>>();
        final selected = result['selected_id'] as int?;
        final screen = result['screen'] as Map<String, Object?>?;
        setState(() {
          if (_selected != selected) {
            _generation++;
            _input.text = _drafts[selected] ?? '';
            _resetRecall();
          }
          _tabs = tabs;
          _selected = selected;
          _output = screen?['text'] as String? ?? '';
          // Polled every 750 ms; only rebuild the patterns when roots change.
          final roots = ShellRoot.listFromJson(result['roots']);
          final rootsKey =
              [for (final r in roots) '${r.label}\u0000${r.path}'].join('\u0001');
          if (rootsKey != _rootsKey) {
            _rootsKey = rootsKey;
            _paths = ShellPaths(roots);
          }
          _fresh = true;
          _error = null;
        });
      } else {
        setState(() {
          _fresh = false;
          _error = outcome is CommandFail
              ? outcome.error.message : 'Connection lost. Reconnecting…';
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _fresh = false;
          _error = 'Unable to read shell sessions.';
        });
      }
    } finally {
      _polling = false;
    }
  }

  void _select(int id) {
    if (_selected == id) return;
    if (_selected != null) _drafts[_selected!] = _input.text;
    setState(() {
      _generation++;
      _selected = id;
      _input.text = _drafts[id] ?? '';
      _resetRecall();
      _output = '';
      _fresh = false;
    });
    _refresh();
  }

  Future<void> _send(String key, {bool includeDraft = true}) async {
    if (!_canInput) return;
    final id = _selected!;
    final draft = includeDraft ? _input.text : '';
    final text = '$draft$key';
    if (text.isEmpty) return;
    if (utf8.encode(text).length > 4096) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Input is limited to 4096 UTF-8 bytes.')),
      );
      return;
    }
    final generation = _generation;
    setState(() => _sending = true);
    try {
      final outcome = await _connection.send(TerminalInput(terminalId: id, text: text));
      if (!mounted || generation != _generation) return;
      if (outcome is CommandOk) {
        if (includeDraft && _input.text == draft) {
          _input.clear();
          _drafts.remove(id);
        }
        if (includeDraft && key == '\r' && draft.trim().isNotEmpty) {
          final sent = _sent.putIfAbsent(id, () => []);
          sent.add(draft);
          if (sent.length > 200) sent.removeAt(0);
          _resetRecall();
        }
        _refresh();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          outcome is CommandFail ? outcome.error.message
              : 'Input delivery is uncertain. Check the shell before retrying.',
        )));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(
          'Input delivery is uncertain. Check the shell before retrying.',
        )));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// ↑ steps back through the tab's history from the live line, ↓ steps
  /// toward it and finally restores it. The recalled command lands in the box
  /// with the caret at its end, to be edited there; nothing reaches the shell
  /// until Enter. The list is read when a recall starts: from the server
  /// (`shell_history` — the shell's own history file, so commands typed on the
  /// computer are there too), else the commands sent from this screen.
  Future<void> _recall(int step) async {
    if (!_fieldEnabled || _loadingHistory) return;
    final at = _recallAt;
    if (at == null) {
      if (step > 0) return;
      final id = _selected!;
      final generation = _generation;
      final list = _serverHistory
          ? await _loadHistory(id)
          : List.of(_sent[id] ?? const <String>[]);
      if (!mounted || generation != _generation || list == null) return;
      final lines = [for (final c in list) if (!c.contains('\n')) c];
      if (lines.isEmpty) return;
      _recallList = lines;
      _liveLine = _input.text;
      _recallAt = lines.length - 1;
    } else {
      final next = at + step;
      if (next >= _recallList.length) {
        final live = _liveLine;
        _resetRecall();
        _setInput(live);
        return;
      }
      _recallAt = next < 0 ? 0 : next;
    }
    _setInput(_recallList[_recallAt!]);
  }

  /// The selected tab's shell history, oldest first; null when it could not
  /// be read (the failure is shown, the box is left alone).
  Future<List<String>?> _loadHistory(int id) async {
    setState(() => _loadingHistory = true);
    try {
      final outcome = await _connection.send(
          RequestTerminals(terminalId: id, history: 200));
      if (outcome is CommandOk) {
        final result = outcome.result.result as Map<String, Object?>;
        if (result['selected_id'] != id) return null;
        return (result['history'] as List? ?? const []).cast<String>();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          outcome is CommandFail ? outcome.error.message
              : 'Unable to read the shell history.',
        )));
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  void _setInput(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _resetRecall() {
    _recallList = const [];
    _recallAt = null;
    _liveLine = '';
  }

  /// Moves the box's caret; [to] maps the current caret to the new one.
  void _moveCaret(int Function(String text, int caret) to) {
    final value = _input.value;
    final caret = value.selection.isValid
        ? value.selection.extentOffset : value.text.length;
    final next = to(value.text, caret).clamp(0, value.text.length);
    _input.selection = TextSelection.collapsed(offset: next);
  }

  static int _wordLeft(String text, int caret) {
    var i = caret;
    while (i > 0 && text[i - 1] == ' ') {
      i--;
    }
    while (i > 0 && text[i - 1] != ' ') {
      i--;
    }
    return i;
  }

  static int _wordRight(String text, int caret) {
    var i = caret;
    while (i < text.length && text[i] == ' ') {
      i++;
    }
    while (i < text.length && text[i] != ' ') {
      i++;
    }
    return i;
  }

  Widget _caretButton(String label, String tooltip,
      int Function(String text, int caret) to,
      {int Function(String text, int caret)? onHold}) => Tooltip(
        message: tooltip,
        child: TextButton(
          onPressed: _fieldEnabled ? () => _moveCaret(to) : null,
          onLongPress: _fieldEnabled && onHold != null
              ? () => _moveCaret(onHold) : null,
          child: Text(label),
        ),
      );

  Widget _keyButton(String label, String keys) => TextButton(
        onPressed: _canInput ? () => _send(keys, includeDraft: false) : null,
        child: Text(label),
      );

  /// A tab's name: its cwd relative to the workspace roots, falling back to
  /// the cwd's last segment, then the shell's title. The id is appended only
  /// when two tabs would otherwise read the same.
  List<String> _tabLabels() {
    String base(Map<String, Object?> tab) {
      final cwd = tab['cwd'] as String? ?? '';
      final relative = _paths.relative(cwd);
      if (relative != null) return relative;
      final segments =
          cwd.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
      if (_paths.isEmpty || segments.isEmpty) {
        return '${tab['title']} · ${tab['id']}';
      }
      return segments.last;
    }

    final names = [for (final tab in _tabs) base(tab)];
    return [
      for (final (i, name) in names.indexed)
        names.where((n) => n == name).length > 1
            ? '$name · ${_tabs[i]['id']}'
            : name,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final instanceName = widget.controller.current?.displayName;
    final labels = _tabLabels();
    final output =
        _shortPaths && !_paths.isEmpty ? _paths.shorten(_output) : _output;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          instanceName == null || instanceName.isEmpty
              ? 'Shell sessions'
              : 'Shell sessions · $instanceName',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!_paths.isEmpty)
            IconButton(
              key: const Key('shell-full-paths'),
              tooltip: _shortPaths ? 'Show full paths' : 'Show short paths',
              icon: Icon(_shortPaths ? Icons.unfold_more : Icons.unfold_less),
              onPressed: () => setState(() => _shortPaths = !_shortPaths),
            ),
        ],
      ),
      body: SafeArea(child: Column(children: [
        ConnectionBanner(connection: _connection,
            instanceName: widget.controller.current?.displayName),
        if (!_supported && _connected)
          const Padding(padding: EdgeInsets.all(16), child: Text(
            'Update Gaviero on this computer to access shell sessions.')),
        if (_tabs.isNotEmpty)
          SizedBox(height: 52, child: ListView(
            scrollDirection: Axis.horizontal,
            children: [for (final (i, tab) in _tabs.indexed)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Text(labels[i]),
                  tooltip: tab['cwd'] as String?,
                  selected: tab['id'] == _selected,
                  onSelected: _sending ? null : (_) => _select(tab['id'] as int),
                )),
            ],
          )),
        // The tab already names the cwd relative to the workspace; the
        // absolute one shows only with full paths (or from older servers).
        if ((!_shortPaths || _paths.isEmpty) &&
            _selected != null &&
            _tabs.any((tab) => tab['id'] == _selected))
          Padding(padding: const EdgeInsets.all(8), child: Text(
            _tabs.firstWhere((tab) => tab['id'] == _selected)['cwd'] as String,
            maxLines: 2, overflow: TextOverflow.ellipsis,
          )),
        if (_error != null) Padding(
          padding: const EdgeInsets.all(8), child: Text(_error!)),
        Expanded(child: _tabs.isEmpty
          ? Center(child: Text(_connected && !_supported
              ? 'Shell access unavailable on this server.'
              : _fresh
              ? 'No shell sessions. Open a terminal in Gaviero on the computer.'
              : 'Waiting for shell sessions…'))
          : Container(
              color: Colors.black,
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(output, style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13, color: Colors.white,
                )),
              )),
            )),
        // The screen above is output only. Ctrl+C and Esc are the only keys
        // that go straight to the shell; everything else edits the box.
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(
          children: [
            _keyButton('Ctrl+C', '\x03'),
            _keyButton('Esc', '\x1b'),
            const SizedBox(width: 8),
            Tooltip(message: 'Previous command', child: TextButton(
              onPressed: _fieldEnabled ? () => _recall(-1) : null,
              child: const Text('↑'),
            )),
            Tooltip(message: 'Next command', child: TextButton(
              onPressed: _fieldEnabled ? () => _recall(1) : null,
              child: const Text('↓'),
            )),
            _caretButton('⇤', 'Start of line', (_, _) => 0),
            _caretButton('←', 'Left (hold: word)', (_, c) => c - 1,
                onHold: _wordLeft),
            _caretButton('→', 'Right (hold: word)', (_, c) => c + 1,
                onHold: _wordRight),
            _caretButton('⇥', 'End of line', (t, _) => t.length),
          ],
        )),
        Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Row(children: [
            Expanded(child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.arrowUp):
                    () => _recall(-1),
                const SingleActivator(LogicalKeyboardKey.arrowDown):
                    () => _recall(1),
              },
              // One line that scrolls sideways under the caret: drag it or
              // use the caret keys to reach any part of a long command.
              child: TextField(
                key: const Key('shell-command'),
                controller: _input,
                enabled: _fieldEnabled,
                autocorrect: false,
                enableSuggestions: false,
                maxLines: 1,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 16),
                  hintText: 'Command',
                  helperText: _fieldEnabled
                      ? '↑ ↓ history · edit here · Enter runs it' : null,
                ),
                onSubmitted: (_) => _send('\r'),
              ),
            )),
            IconButton(tooltip: 'Enter',
                icon: const Icon(Icons.keyboard_return),
                onPressed: _canInput ? () => _send('\r') : null),
          ]),
        ),
      ])),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connection.removeListener(_connectionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    super.dispose();
  }
}
