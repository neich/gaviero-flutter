/// Result payloads for the 1.3 `file_browser` commands. `command_result.result`
/// is untyped on the wire; these decoders are the client's contract with
/// PROTOCOL.md §File browser.
library;

final class DirectoryEntry {
  final String name;
  final String path;
  final bool isDir;
  final int? size;

  const DirectoryEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size,
  });

  factory DirectoryEntry.fromJson(Map<String, Object?> json) => DirectoryEntry(
    name: json['name'] as String,
    path: json['path'] as String,
    isDir: json['is_dir'] as bool,
    size: json['size'] as int?,
  );
}

final class DirectoryListing {
  final String path;
  final List<DirectoryEntry> roots;
  final List<DirectoryEntry> entries;
  final bool truncated;

  const DirectoryListing({
    required this.path,
    required this.roots,
    required this.entries,
    required this.truncated,
  });

  factory DirectoryListing.fromJson(Map<String, Object?> json) =>
      DirectoryListing(
        path: json['path'] as String? ?? '',
        roots: [
          for (final r in (json['roots'] as List?) ?? const [])
            DirectoryEntry.fromJson(r as Map<String, Object?>),
        ],
        entries: [
          for (final e in (json['entries'] as List?) ?? const [])
            DirectoryEntry.fromJson(e as Map<String, Object?>),
        ],
        truncated: json['truncated'] as bool? ?? false,
      );
}

/// One highlight run: UTF-8 byte offsets into [FileContent.content].
final class FileSpan {
  final int startByte;
  final int endByte;
  final String className;

  const FileSpan(this.startByte, this.endByte, this.className);
}

final class FileContent {
  final String path;
  final bool viewable;
  final String? reason; // binary | not_utf8 | not_a_file
  final String? language;
  final int bytes;
  final bool truncated;
  final String content;
  final List<FileSpan> spans;
  final bool spansTruncated;

  const FileContent({
    required this.path,
    required this.viewable,
    this.reason,
    this.language,
    required this.bytes,
    required this.truncated,
    required this.content,
    this.spans = const [],
    this.spansTruncated = false,
  });

  bool get isMarkdown => language == 'markdown';

  factory FileContent.fromJson(Map<String, Object?> json) {
    final classes = ((json['classes'] as List?) ?? const []).cast<String>();
    final spans = <FileSpan>[];
    for (final raw in (json['spans'] as List?) ?? const []) {
      final triple = raw as List;
      if (triple.length < 3) continue;
      final index = triple[2] as int;
      if (index < 0 || index >= classes.length) continue;
      spans.add(FileSpan(triple[0] as int, triple[1] as int, classes[index]));
    }
    return FileContent(
      path: json['path'] as String? ?? '',
      viewable: json['viewable'] as bool? ?? false,
      reason: json['reason'] as String?,
      language: json['language'] as String?,
      bytes: json['bytes'] as int? ?? 0,
      truncated: json['truncated'] as bool? ?? false,
      content: json['content'] as String? ?? '',
      spans: spans,
      spansTruncated: json['spans_truncated'] as bool? ?? false,
    );
  }
}
