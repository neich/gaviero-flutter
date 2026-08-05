/// Protocol offsets (`CodeBlock`, `Span`) are UTF-8 byte offsets into
/// `Message.content` with exclusive ends. Dart strings are UTF-16, so
/// `String.substring` on those offsets silently mis-highlights any message
/// containing an accent, an emoji, or a box-drawing character. Encode once,
/// slice bytes, decode each slice.
library;

import 'dart:convert';
import 'dart:typed_data';

final class Utf8Text {
  final String content;
  final Uint8List bytes;

  Utf8Text(this.content) : bytes = utf8.encode(content);

  int get byteLength => bytes.length;

  /// Slices by UTF-8 byte offsets, end exclusive. Out-of-range or inverted
  /// offsets are clamped — a malformed span must never crash rendering.
  String slice(int startByte, int endByte) {
    final start = startByte.clamp(0, bytes.length);
    final end = endByte.clamp(start, bytes.length);
    return utf8.decode(bytes.sublist(start, end), allowMalformed: true);
  }
}

/// A run of text with an optional highlight class, produced by
/// [classifyRuns].
final class ClassedRun {
  final String text;

  /// Semantic tree-sitter capture name, or null for plain text.
  final String? className;

  const ClassedRun(this.text, this.className);
}

/// Splits `[startByte, endByte)` of [text] into plain/classed runs from
/// absolute-offset spans (sorted, non-overlapping per the protocol; overlaps
/// and out-of-range spans are clamped defensively).
List<ClassedRun> classifyRuns(
  Utf8Text text,
  int startByte,
  int endByte,
  Iterable<({int startByte, int endByte, String className})> spans,
) {
  final runs = <ClassedRun>[];
  var cursor = startByte;
  final sorted = spans.toList()
    ..sort((a, b) => a.startByte.compareTo(b.startByte));
  for (final span in sorted) {
    final s = span.startByte.clamp(cursor, endByte);
    final e = span.endByte.clamp(s, endByte);
    if (s > cursor) runs.add(ClassedRun(text.slice(cursor, s), null));
    if (e > s) runs.add(ClassedRun(text.slice(s, e), span.className));
    cursor = e > cursor ? e : cursor;
  }
  if (cursor < endByte) {
    runs.add(ClassedRun(text.slice(cursor, endByte), null));
  }
  return runs;
}
