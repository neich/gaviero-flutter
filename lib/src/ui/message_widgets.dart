/// Message rendering (B4). Completed assistant messages are split at the
/// server-declared code-block byte ranges: prose segments go through
/// `GptMarkdown`, code segments render natively with the server's highlight
/// spans (so absolute UTF-8 byte offsets never have to be re-located inside
/// a markdown widget). The still-streaming buffer has no spans yet and is
/// rendered by `GptMarkdown`.
///
/// Both are also split at the providers' `<think>` / `</think>` framing:
/// a reasoning block collapses to a "Thinking…" header with a one-line gist
/// and unfolds on tap. Code never scrolls sideways — long lines wrap.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../protocol/protocol.dart';
import '../util/utf8_spans.dart';
import 'theme.dart';

/// Provider framing for a reasoning block, written verbatim into the
/// assistant text by every desktop provider.
const _thinkOpen = '<think>';
const _thinkClose = '</think>';
final _thinkOpenBytes = utf8.encode(_thinkOpen);
final _thinkCloseBytes = utf8.encode(_thinkClose);

sealed class _Segment {
  const _Segment();
}

final class _Prose extends _Segment {
  final String text;
  const _Prose(this.text);
}

final class _Code extends _Segment {
  final CodeBlock block;
  const _Code(this.block);
}

final class _Thinking extends _Segment {
  final String body;

  /// False while the block is still streaming (or the message was truncated
  /// before its close tag).
  final bool closed;
  const _Thinking(this.body, {required this.closed});
}

int _indexOfBytes(Uint8List haystack, List<int> needle, int from) {
  outer:
  for (var i = from; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Byte ranges of every `<think>` block, tags included. An unclosed block
/// runs to the end of the text.
List<({int start, int end, String body, bool closed})> _thinkingRanges(
    Utf8Text text) {
  final ranges = <({int start, int end, String body, bool closed})>[];
  var cursor = 0;
  while (true) {
    final open = _indexOfBytes(text.bytes, _thinkOpenBytes, cursor);
    if (open < 0) break;
    final bodyStart = open + _thinkOpenBytes.length;
    final close = _indexOfBytes(text.bytes, _thinkCloseBytes, bodyStart);
    if (close < 0) {
      ranges.add((
        start: open,
        end: text.byteLength,
        body: text.slice(bodyStart, text.byteLength),
        closed: false,
      ));
      break;
    }
    cursor = close + _thinkCloseBytes.length;
    ranges.add((
      start: open,
      end: cursor,
      body: text.slice(bodyStart, close),
      closed: true,
    ));
  }
  return ranges;
}

/// Splits [content] into prose, code, and reasoning segments. Code blocks
/// the server found inside a reasoning block stay part of that block.
List<_Segment> _segment(String content, List<CodeBlock> codeBlocks) {
  if (codeBlocks.isEmpty && !content.contains(_thinkOpen)) {
    return [_Prose(content)];
  }
  final text = Utf8Text(content);
  final thinking = _thinkingRanges(text);
  final regions = <({int start, int end, _Segment segment})>[
    for (final t in thinking)
      (start: t.start, end: t.end, segment: _Thinking(t.body, closed: t.closed)),
    for (final block in codeBlocks)
      if (!thinking
          .any((t) => block.startByte < t.end && block.endByte > t.start))
        (start: block.startByte, end: block.endByte, segment: _Code(block)),
  ]..sort((a, b) => a.start.compareTo(b.start));
  final segments = <_Segment>[];
  var cursor = 0;
  void prose(int end) {
    if (end <= cursor) return;
    final slice = text.slice(cursor, end);
    if (slice.trim().isNotEmpty) segments.add(_Prose(slice));
  }

  for (final region in regions) {
    prose(region.start);
    segments.add(region.segment);
    cursor = region.end > cursor ? region.end : cursor;
  }
  prose(text.byteLength);
  return segments;
}

/// Strips the fence lines from a block slice; the fenced range includes the
/// fences themselves (§3.1) but the spans only ever land inside the body.
({String body, int bodyStartByte}) _fenceBody(Utf8Text text, CodeBlock block) {
  final full = text.slice(block.startByte, block.endByte);
  final firstNewline = full.indexOf('\n');
  if (firstNewline < 0) return (body: full, bodyStartByte: block.startByte);
  final closingFence = full.lastIndexOf('```');
  final body = closingFence > firstNewline
      ? full.substring(firstNewline + 1, closingFence)
      : full.substring(firstNewline + 1);
  final bodyStartByte =
      block.startByte + Utf8Text(full.substring(0, firstNewline + 1)).byteLength;
  return (body: body, bodyStartByte: bodyStartByte);
}

/// The dark code panel shared by server-highlighted blocks and the fences
/// `GptMarkdown` finds in streaming text. Lines wrap at the bubble edge.
class _CodeFrame extends StatelessWidget {
  final String? language;
  final String? note;
  final InlineSpan code;

  const _CodeFrame({this.language, this.note, required this.code});

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(color: Colors.white38);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: codeBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (language != null || note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                children: [
                  if (language != null) Text(language!, style: labelStyle),
                  const Spacer(),
                  if (note != null) Text(note!, style: labelStyle),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text.rich(
              code,
              softWrap: true,
              style: const TextStyle(
                fontFamily: codeFontFamily,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CodeBlockView extends StatelessWidget {
  final Utf8Text text;
  final CodeBlock block;

  const CodeBlockView({super.key, required this.text, required this.block});

  @override
  Widget build(BuildContext context) {
    final (body: body, bodyStartByte: bodyStart) = _fenceBody(text, block);
    final bodyEnd = bodyStart + Utf8Text(body).byteLength;
    final List<InlineSpan> spans;
    if (block.truncated || block.spans.isEmpty) {
      spans = [TextSpan(text: body)];
    } else {
      final runs = classifyRuns(
        text,
        bodyStart,
        bodyEnd,
        block.spans.map((s) => (
              startByte: s.startByte,
              endByte: s.endByte,
              className: s.className,
            )),
      );
      spans = [
        for (final run in runs)
          TextSpan(text: run.text, style: highlightStyle(run.className)),
      ];
    }
    return _CodeFrame(
      language: block.language,
      note: block.truncated ? 'too large to highlight' : null,
      code: TextSpan(children: spans),
    );
  }
}

/// `GptMarkdown` with the app's wrapping code panel in place of the
/// package's horizontally scrolling one.
class MarkdownText extends StatelessWidget {
  final String data;
  final TextStyle? style;

  const MarkdownText(this.data, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    return GptMarkdown(
      data,
      style: style,
      codeBuilder: (context, name, code, closed) =>
          // Rendered inside a WidgetSpan, which already scales its child.
          MediaQuery.withNoTextScaling(
        child: _CodeFrame(
          language: name.trim().isEmpty ? null : name.trim(),
          code: TextSpan(text: code.trimRight()),
        ),
      ),
    );
  }
}

/// One line of gist for a collapsed reasoning block: the opening of a
/// finished block, the latest words of a live one. Markdown emphasis is
/// dropped — it is noise at this size.
String _thinkingGist(String body, {required bool live}) {
  final flat = body
      .replaceAll(RegExp(r'[*_`#>]+'), '')
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .join(' ');
  const tailChars = 140;
  if (!live || flat.length <= tailChars) return flat;
  var start = flat.length - tailChars;
  // Never start on the low half of a surrogate pair.
  if ((flat.codeUnitAt(start) & 0xFC00) == 0xDC00) start++;
  return '…${flat.substring(start)}';
}

/// A collapsed `<think>` block: a header, a one-line gist, and the full
/// reasoning on tap.
class ThinkingBlock extends StatefulWidget {
  final String body;

  /// True while the provider is still streaming this block.
  final bool live;

  const ThinkingBlock({super.key, required this.body, required this.live});

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const muted = Colors.white54;
    final gist = _thinkingGist(widget.body, live: widget.live);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.only(left: 10),
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Colors.white24, width: 2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (widget.live)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: theme.colorScheme.secondary),
                  )
                else
                  const Icon(Icons.psychology_outlined, size: 14, color: muted),
                const SizedBox(width: 6),
                Text(widget.live ? 'Thinking…' : 'Thought',
                    style: theme.textTheme.labelMedium?.copyWith(color: muted)),
                const Spacer(),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: muted),
              ],
            ),
            if (!_expanded && gist.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  gist,
                  maxLines: widget.live ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: muted, fontStyle: FontStyle.italic),
                ),
              ),
            if (_expanded && widget.body.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: MarkdownText(
                  widget.body.trim(),
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final Message message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == Role.user;
    final scheme = Theme.of(context).colorScheme;
    final text = Utf8Text(message.content);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: switch (message.role) {
            Role.user => scheme.primaryContainer,
            Role.assistant => scheme.surfaceContainerHigh,
            Role.system => scheme.surfaceContainerLow,
          },
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final tool in message.toolCalls) ToolCallRow(toolName: tool),
            if (isUser || message.role == Role.system)
              SelectableText(message.content)
            else
              for (final segment in _segment(message.content, message.codeBlocks))
                switch (segment) {
                  _Prose(:final text) => MarkdownText(text.trim()),
                  _Code(:final block) =>
                    CodeBlockView(text: text, block: block),
                  _Thinking(:final body) =>
                    ThinkingBlock(body: body, live: false),
                },
            if (message.truncated) TruncatedNotice(message: message),
          ],
        ),
      ),
    );
  }
}

class ToolCallRow extends StatelessWidget {
  final String toolName;

  const ToolCallRow({super.key, required this.toolName});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.build_outlined,
              size: 14, color: Theme.of(context).colorScheme.secondary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(toolName,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.secondary)),
          ),
        ],
      ),
    );
  }
}

/// Honest elision (§3.6): the head of a >128 KiB message is shown; the rest
/// exists only on the desktop.
class TruncatedNotice extends StatelessWidget {
  final Message message;

  const TruncatedNotice({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final size = message.fullBytes;
    final label = size == null
        ? 'Message truncated — view the rest on the desktop'
        : 'Truncated — ${_formatBytes(size)} total, view the rest on the '
            'desktop';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.unfold_more, size: 14, color: Colors.white38),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Colors.white38)),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// The in-progress assistant turn: streamed text (no spans yet — the server
/// highlights only completed messages), live tool rows, and the status line
/// as a typing indicator.
class StreamingBubble extends StatelessWidget {
  final String text;
  final String? status;
  final List<String> toolCalls;

  const StreamingBubble({
    super.key,
    required this.text,
    required this.status,
    required this.toolCalls,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final tool in toolCalls) ToolCallRow(toolName: tool),
            if (text.isNotEmpty)
              for (final segment in _segment(text, const []))
                switch (segment) {
                  _Prose(:final text) => MarkdownText(text.trim()),
                  // Streaming text carries no code-block ranges.
                  _Code() => const SizedBox.shrink(),
                  _Thinking(:final body, :final closed) =>
                    ThinkingBlock(body: body, live: !closed),
                },
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: scheme.secondary),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(status ?? 'streaming…',
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(color: scheme.secondary)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
