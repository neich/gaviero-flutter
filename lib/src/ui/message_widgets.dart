/// Message rendering (B4). Completed assistant messages are split at the
/// server-declared code-block byte ranges: prose segments go through
/// `GptMarkdown`, code segments render natively with the server's highlight
/// spans (so absolute UTF-8 byte offsets never have to be re-located inside
/// a markdown widget). The still-streaming buffer has no spans yet and is
/// rendered whole by `GptMarkdown`.
library;

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../protocol/protocol.dart';
import '../util/utf8_spans.dart';
import 'theme.dart';

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

List<_Segment> _segment(Message message) {
  if (message.codeBlocks.isEmpty) return [_Prose(message.content)];
  final text = Utf8Text(message.content);
  final segments = <_Segment>[];
  var cursor = 0;
  final blocks = [...message.codeBlocks]
    ..sort((a, b) => a.startByte.compareTo(b.startByte));
  for (final block in blocks) {
    if (block.startByte > cursor) {
      final prose = text.slice(cursor, block.startByte);
      if (prose.trim().isNotEmpty) segments.add(_Prose(prose));
    }
    segments.add(_Code(block));
    cursor = block.endByte > cursor ? block.endByte : cursor;
  }
  if (cursor < text.byteLength) {
    final prose = text.slice(cursor, text.byteLength);
    if (prose.trim().isNotEmpty) segments.add(_Prose(prose));
  }
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
          if (block.language != null || block.truncated)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                children: [
                  if (block.language != null)
                    Text(block.language!,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Colors.white38)),
                  const Spacer(),
                  if (block.truncated)
                    Text('too large to highlight',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: Colors.white38)),
                ],
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Text.rich(
              TextSpan(children: spans),
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
              for (final segment in _segment(message))
                switch (segment) {
                  _Prose(:final text) => GptMarkdown(text.trim()),
                  _Code(:final block) =>
                    CodeBlockView(text: text, block: block),
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
          Text(toolName,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.secondary)),
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
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Colors.white38)),
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
            if (text.isNotEmpty) GptMarkdown(text),
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
                  Text(status ?? 'streaming…',
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: scheme.secondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
