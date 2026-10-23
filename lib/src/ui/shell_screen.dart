import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../protocol/client_frames.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import 'chat_screen.dart';

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
  /// Commands run from this screen, oldest first. Recalling one only touches
  /// the box, never the PTY's line buffer, so it can be edited before sending.
  final _history = <String>[];
  /// Position in [_history] while recalling, or null when on the live line.
  int? _historyAt;
  /// The line being typed when recall started, restored past the newest entry.
  String _liveLine = '';
  Timer? _timer;
  List<Map<String, Object?>> _tabs = [];
  int? _selected;
  String _output = '';
  String? _error;
  bool _polling = false;
  bool _sending = false;
  bool _fresh = false;
  bool _foreground = true;
  int _generation = 0;

  RemoteConnection get _connection => widget.controller.connection;
  bool get _supported =>
      _connection.hello?.capabilities.contains('shell_sessions') ?? false;
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
          _remember(draft);
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

  /// Walks [_history] the way a shell does: ↑ steps back from the live line,
  /// ↓ steps toward it and restores it, and the caret lands at the end of the
  /// recalled entry so it can be edited in place.
  void _recall(int step) {
    if (_history.isEmpty) return;
    final at = _historyAt;
    if (at == null) {
      if (step > 0) return;
      _liveLine = _input.text;
      _historyAt = _history.length - 1;
    } else {
      final next = at + step;
      if (next >= _history.length) {
        _historyAt = null;
        _setInput(_liveLine);
        _liveLine = '';
        return;
      }
      _historyAt = next < 0 ? 0 : next;
    }
    _setInput(_history[_historyAt!]);
  }

  void _setInput(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Keeps a command that actually ran so it can be recalled and edited.
  void _remember(String command) {
    _history.add(command);
    if (_history.length > 200) _history.removeAt(0);
    _resetRecall();
  }

  void _resetRecall() {
    _historyAt = null;
    _liveLine = '';
  }

  Widget _keyButton(String label, String keys, {bool includeDraft = false}) =>
      TextButton(
        onPressed: _canInput
            ? () => _send(keys, includeDraft: includeDraft) : null,
        child: Text(label),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shell sessions')),
      body: SafeArea(child: Column(children: [
        ConnectionBanner(connection: _connection,
            instanceName: widget.controller.current?.displayName),
        if (!_supported && _connected)
          const Padding(padding: EdgeInsets.all(16), child: Text(
            'Update Gaviero on this computer to access shell sessions.')),
        if (_tabs.isNotEmpty)
          SizedBox(height: 52, child: ListView(
            scrollDirection: Axis.horizontal,
            children: [for (final tab in _tabs)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Text('${tab['title']} · ${tab['id']}'),
                  selected: tab['id'] == _selected,
                  onSelected: _sending ? null : (_) => _select(tab['id'] as int),
                )),
            ],
          )),
        if (_selected != null && _tabs.any((tab) => tab['id'] == _selected))
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
                child: SelectableText(_output, style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13, color: Colors.white,
                )),
              )),
            )),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(
          children: [
            _keyButton('Ctrl+C', '\x03'),
            _keyButton('Esc', '\x1b'),
            _keyButton('Tab', '\t', includeDraft: true),
            // ↑/↓ put a command back in the box so it can be edited; holding
            // one still sends the arrow key itself to the shell.
            TextButton(
              onPressed: _fieldEnabled ? () => _recall(-1) : null,
              onLongPress: _canInput
                  ? () => _send('\x1b[A', includeDraft: false) : null,
              child: const Text('↑'),
            ),
            TextButton(
              onPressed: _fieldEnabled ? () => _recall(1) : null,
              onLongPress: _canInput
                  ? () => _send('\x1b[B', includeDraft: false) : null,
              child: const Text('↓'),
            ),
            _keyButton('←', '\x1b[D'),
            _keyButton('→', '\x1b[C'),
            _keyButton('⌫', '\x7f'),
          ],
        )),
        Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          Expanded(child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.arrowUp):
                  () => _recall(-1),
              const SingleActivator(LogicalKeyboardKey.arrowDown):
                  () => _recall(1),
            },
            child: TextField(
              controller: _input,
              enabled: _fieldEnabled,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: 'Command or shell input',
                helperText: _fieldEnabled
                    ? '↑ ↓ history · hold a key to send the arrow' : null,
              ),
              onSubmitted: (_) => _send('\r'),
            ),
          )),
          TextButton(onPressed: _canInput ? () => _send('') : null,
              child: const Text('Type')),
          IconButton(tooltip: 'Enter', icon: const Icon(Icons.keyboard_return),
              onPressed: _canInput ? () => _send('\r') : null),
        ])),
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
