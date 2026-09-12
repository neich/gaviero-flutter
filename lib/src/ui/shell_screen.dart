import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

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
  bool get _canInput =>
      _connected && _supported && _fresh && !_sending && _selected != null;

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
          instanceId != _connection.instanceId) return;
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
            for (final key in <(String, String)>[
              ('Ctrl+C', '\x03'), ('Esc', '\x1b'), ('Tab', '\t'),
              ('↑', '\x1b[A'), ('↓', '\x1b[B'),
              ('←', '\x1b[D'), ('→', '\x1b[C'), ('⌫', '\x7f'),
            ]) TextButton(
              onPressed: _canInput ? () => _send(key.$2,
                  includeDraft: key.$1 == 'Tab') : null,
              child: Text(key.$1),
            ),
          ],
        )),
        Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          Expanded(child: TextField(
            controller: _input,
            enabled: _connected && _supported && _fresh && _selected != null,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(hintText: 'Command or shell input'),
            onSubmitted: (_) => _send('\r'),
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
