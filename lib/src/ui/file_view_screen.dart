import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../protocol/protocol.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import '../util/links.dart';
import '../util/markdown_anchors.dart';
import '../util/utf8_spans.dart';
import 'link_actions.dart';
import 'message_widgets.dart';
import 'theme.dart';

/// Read-only file view. Code is rendered from the server's tree-sitter
/// capture classes; Markdown defaults to a rendered preview with a Raw
/// toggle. There is deliberately no save/rename/delete affordance.
///
/// Links in the preview are followed: web links leave the app, workspace
/// links (relative to this file) open another viewer, a line target
/// (`#L42`, `#L10-L20`) scrolls to those lines and marks them — in the Raw
/// view for Markdown, where lines exist — and a heading anchor (`#install`)
/// scrolls the preview to that heading.
class FileViewScreen extends StatefulWidget {
  final RemoteController controller;
  final String path;
  final String name;

  /// 1-based line to scroll to and mark, through [endLine] when given.
  final int? startLine;
  final int? endLine;

  /// Heading to scroll to in a Markdown preview (a link's `#fragment`).
  final String? anchor;

  const FileViewScreen({
    super.key,
    required this.controller,
    required this.path,
    required this.name,
    this.startLine,
    this.endLine,
    this.anchor,
  });

  @override
  State<FileViewScreen> createState() => _FileViewScreenState();
}

class _FileViewScreenState extends State<FileViewScreen> {
  FileContent? _content;
  String? _error;
  late bool _preview = widget.startLine == null;
  late int? _startLine = widget.startLine;
  late int? _endLine = widget.endLine;
  late String? _anchor = widget.startLine == null ? widget.anchor : null;
  late bool _jumpPending = widget.startLine != null || _anchor != null;
  int _generation = 0;
  final _scroll = ScrollController();
  final _textKey = GlobalKey();

  /// The Markdown preview, one widget per heading so links can reach them.
  List<MarkdownSection> _sections = const [];
  List<GlobalKey> _sectionKeys = const [];

  RemoteConnection get _connection => widget.controller.connection;

  @override
  void initState() {
    super.initState();
    _connection.addListener(_connectionChanged);
    _load();
  }

  void _onLink(String href) {
    followLink(
      context,
      widget.controller,
      href,
      fromFile: widget.path,
      openFile: (link) {
        if (link.path == widget.path) {
          _showTarget(link);
        } else {
          Navigator.of(context).push(fileViewRoute(widget.controller, link));
        }
      },
    );
  }

  /// A link into this same file: reveal its heading in the preview, or
  /// mark and reveal its lines in place (the top for a bare `#`).
  void _showTarget(FileLink link) {
    setState(() {
      if (link.anchor case final anchor?) {
        _anchor = anchor;
        _preview = true;
      } else {
        _anchor = null;
        _startLine = link.startLine;
        _endLine = link.endLine;
        if (link.startLine != null) _preview = false;
      }
      _jumpPending = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _jump());
  }

  /// Scrolls the marked first line near the top, a few lines of context
  /// above it. Runs after layout: the offset comes from the laid-out text,
  /// so wrapped lines are counted correctly.
  void _jump() {
    if (!mounted || !_jumpPending || !_scroll.hasClients) return;
    _jumpPending = false;
    final anchor = _anchor;
    if (anchor != null && _preview && _content?.isMarkdown == true) {
      _jumpToHeading(anchor);
      return;
    }
    final start = _startLine;
    if (start == null) {
      _scroll.jumpTo(0);
      return;
    }
    final editable = _findEditable(_textKey.currentContext?.findRenderObject());
    final viewport = editable == null
        ? null
        : RenderAbstractViewport.maybeOf(editable);
    if (editable == null || viewport == null) return;
    final text = editable.text?.toPlainText() ?? '';
    final caret = editable.getLocalRectForCaret(
      TextPosition(offset: _lineStart(text, start)),
    );
    final target = viewport.getOffsetToReveal(editable, 0, rect: caret).offset;
    final position = _scroll.position;
    _scroll.jumpTo(
      (target - 3 * caret.height).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  /// Puts the heading [anchor] names at the top of the preview.
  void _jumpToHeading(String anchor) {
    final index = findSection(_sections, anchor);
    final target = index == null ? null : _sectionKeys[index].currentContext;
    if (target == null) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('No heading “#$anchor” in this document.')),
        );
      return;
    }
    Scrollable.ensureVisible(target);
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
        final sections = content.isMarkdown
            ? splitAtHeadings(content.content)
            : const <MarkdownSection>[];
        setState(() {
          _content = content;
          _error = null;
          _sections = sections;
          _sectionKeys = [for (final _ in sections) GlobalKey()];
        });
        if (_jumpPending) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _jump());
        }
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
    _scroll.dispose();
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
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            child: _contentBody(content),
          ),
        ),
      ],
    );
  }

  Widget _contentBody(FileContent content) {
    if (content.isMarkdown && _preview) {
      if (_sections.length < 2) {
        return KeyedSubtree(
          key: _sectionKeys.firstOrNull,
          child: MarkdownText(content.content, onLinkTap: _onLink),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, section) in _sections.indexed)
            KeyedSubtree(
              key: _sectionKeys[i],
              child: MarkdownText(section.text, onLinkTap: _onLink),
            ),
        ],
      );
    }
    return _code(content);
  }

  /// Highlighted source (raw text for Markdown, or when the server sent no
  /// spans), with the linked lines marked.
  Widget _code(FileContent file) {
    final List<(String, TextStyle?)> runs;
    if (file.isMarkdown || file.spans.isEmpty) {
      runs = [(file.content, null)];
    } else {
      final text = Utf8Text(file.content);
      runs = [
        for (final run in classifyRuns(
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
        ))
          (run.text, highlightStyle(run.className)),
      ];
    }
    final start = _startLine;
    final children = start == null
        ? [for (final (text, style) in runs) TextSpan(text: text, style: style)]
        : markLines(
            runs,
            start,
            _endLine ?? start,
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
          );
    return SelectableText.rich(
      key: _textKey,
      TextSpan(children: children),
      style: const TextStyle(
        fontFamily: codeFontFamily,
        fontSize: 13,
        height: 1.4,
      ),
    );
  }
}

/// [runs] as spans, split at line ends so lines [first]..[last] (1-based,
/// inclusive) carry a [background].
List<TextSpan> markLines(
  List<(String, TextStyle?)> runs,
  int first,
  int last,
  Color background,
) {
  final spans = <TextSpan>[];
  var line = 1;
  for (final (text, style) in runs) {
    var from = 0;
    while (from < text.length) {
      final newline = text.indexOf('\n', from);
      final to = newline < 0 ? text.length : newline + 1;
      final marked = line >= first && line <= last;
      spans.add(
        TextSpan(
          text: text.substring(from, to),
          style: marked
              ? (style ?? const TextStyle()).copyWith(
                  backgroundColor: background,
                )
              : style,
        ),
      );
      if (newline >= 0) line++;
      from = to;
    }
  }
  return spans;
}

/// UTF-16 offset where 1-based [line] starts; the end of [text] when it has
/// fewer lines (a truncated file).
int _lineStart(String text, int line) {
  var offset = 0;
  for (var i = 1; i < line; i++) {
    final newline = text.indexOf('\n', offset);
    if (newline < 0) return text.length;
    offset = newline + 1;
  }
  return offset;
}

RenderEditable? _findEditable(RenderObject? root) {
  RenderEditable? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderEditable) {
      found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  if (root != null) visit(root);
  return found;
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
