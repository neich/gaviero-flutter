import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import '../util/utf8_spans.dart';
import 'message_widgets.dart';
import 'theme.dart';

/// Read-only file view. Code is rendered from the server's tree-sitter
/// capture classes; Markdown defaults to a rendered preview with a Raw
/// toggle. There is deliberately no save/rename/delete affordance.
class FileViewScreen extends StatefulWidget {
  final RemoteController controller;
  final String path;
  final String name;

  const FileViewScreen({
    super.key,
    required this.controller,
    required this.path,
    required this.name,
  });

  @override
  State<FileViewScreen> createState() => _FileViewScreenState();
}

class _FileViewScreenState extends State<FileViewScreen> {
  FileContent? _content;
  String? _error;
  bool _preview = true;
  int _generation = 0;

  RemoteConnection get _connection => widget.controller.connection;

  @override
  void initState() {
    super.initState();
    _connection.addListener(_connectionChanged);
    _load();
  }

  /// A file that failed while offline loads itself once the link is back.
  void _connectionChanged() {
    if (!mounted) return;
    if (_connection.phase == ConnectionPhase.connected && _content == null) {
      _generation++;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = _generation;
    try {
      final outcome = await widget.controller.requestFile(widget.path);
      if (!mounted || generation != _generation) return;
      if (outcome is CommandOk) {
        final content = FileContent.fromJson(
          outcome.result.result as Map<String, Object?>,
        );
        setState(() {
          _content = content;
          _error = null;
        });
      } else if (outcome is CommandFail) {
        setState(() => _error = outcome.error.message);
      } else {
        setState(() => _error = 'Connection lost. Reconnecting…');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Unable to read this file.');
      }
    }
  }

  @override
  void dispose() {
    _connection.removeListener(_connectionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _content;
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: SafeArea(child: _body(content)),
    );
  }

  Widget _body(FileContent? content) {
    if (content == null) {
      return _error == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(_error!),
            );
    }
    if (!content.viewable) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.visibility_off_outlined, size: 40),
            const SizedBox(height: 12),
            Text(_unviewableReason(content.reason)),
          ],
        ),
      );
    }
    return Column(
      children: [
        if (content.truncated)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.all(12),
            child: Text(
              'Showing the first ${_bytes(Utf8Text(content.content).byteLength)} '
              'of ${_bytes(content.bytes)} — highlighting is off for '
              'truncated files.',
            ),
          ),
        if (content.isMarkdown)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Preview')),
                ButtonSegment(value: false, label: Text('Raw')),
              ],
              selected: {_preview},
              onSelectionChanged: (selection) =>
                  setState(() => _preview = selection.first),
            ),
          ),
        if (content.spansTruncated)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('Highlighting stops early on this file.'),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: _contentBody(content),
          ),
        ),
      ],
    );
  }

  Widget _contentBody(FileContent content) {
    if (content.isMarkdown && _preview) {
      return MarkdownText(content.content);
    }
    if (content.isMarkdown) {
      return _plainCode(content.content);
    }
    return _code(content);
  }

  Widget _code(FileContent file) {
    final text = Utf8Text(file.content);
    final List<InlineSpan> children;
    if (file.spans.isEmpty) {
      children = [TextSpan(text: file.content)];
    } else {
      final runs = classifyRuns(
        text,
        0,
        text.byteLength,
        file.spans.map(
          (s) => (
            startByte: s.startByte,
            endByte: s.endByte,
            className: s.className,
          ),
        ),
      );
      children = [
        for (final run in runs)
          TextSpan(text: run.text, style: highlightStyle(run.className)),
      ];
    }
    return SelectableText.rich(
      TextSpan(children: children),
      style: const TextStyle(
        fontFamily: codeFontFamily,
        fontSize: 13,
        height: 1.4,
      ),
    );
  }

  Widget _plainCode(String content) => SelectableText(
    content,
    style: const TextStyle(
      fontFamily: codeFontFamily,
      fontSize: 13,
      height: 1.4,
    ),
  );
}

String _unviewableReason(String? reason) => switch (reason) {
  'binary' => 'Binary file — not shown.',
  'not_utf8' => 'Not UTF-8 text — not shown.',
  'not_a_file' => 'Not a regular file.',
  _ => 'This file cannot be shown.',
};

String _bytes(int n) => n < 1024
    ? '$n B'
    : n < 1024 * 1024
    ? '${(n / 1024).toStringAsFixed(1)} KiB'
    : '${(n / (1024 * 1024)).toStringAsFixed(1)} MiB';
