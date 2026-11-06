/// Markdown link targets. Web links leave the app; everything else is a
/// workspace path in the `<root-label>/<rel>` namespace of PROTOCOL.md
/// §File browser.
///
/// This is the one place the client joins paths: a relative link only means
/// something against the file it appears in. The result is clamped to that
/// file's root and the desktop still validates every `read_file` path (`..`,
/// absolute paths and escapes are refused there), so a wrong join can fail
/// but never reach outside the workspace.
library;

sealed class LinkTarget {
  const LinkTarget();
}

/// http / https / mailto — opened by the phone.
final class WebLink extends LinkTarget {
  final Uri uri;
  const WebLink(this.uri);
}

/// A workspace file, optionally at a line range (`#L42`, `#L10-L20`,
/// `path:42`).
final class FileLink extends LinkTarget {
  final String path;
  final int? startLine;
  final int? endLine;

  const FileLink(this.path, {this.startLine, this.endLine});

  String get name => path.split('/').last;
}

/// A workspace path from chat, which can only be resolved once the
/// workspace root labels are known: call [resolveLink] again with `roots`.
final class NeedsRoots extends LinkTarget {
  const NeedsRoots();
}

/// A link this app does not follow; [reason] is shown to the user.
final class UnsupportedLink extends LinkTarget {
  final String reason;
  const UnsupportedLink(this.reason);
}

const _webSchemes = {'http', 'https', 'mailto'};
final _scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.\-]*):');
final _lineFragment = RegExp(r'^L(\d+)(?:-L?(\d+))?$');
final _lineSuffix = RegExp(r':(\d+)(?:-(\d+))?$');

/// Resolves the `href` of a Markdown link.
///
/// [fromFile] is the workspace path of the document holding the link:
/// relative links resolve against its folder and `/x` against its root.
/// Without it (chat), the path is workspace-relative: a first segment
/// naming one of [roots] picks that folder, anything else is read from the
/// first root (the desktop's primary folder).
LinkTarget resolveLink(
  String href, {
  String? fromFile,
  List<String> roots = const [],
}) {
  var raw = href.trim();
  if (raw.startsWith('<') && raw.endsWith('>')) {
    raw = raw.substring(1, raw.length - 1).trim();
  }
  if (raw.isEmpty) return const UnsupportedLink('This link is empty.');

  final scheme = _scheme.firstMatch(raw)?.group(1)?.toLowerCase();
  // One letter is a Windows drive (`C:\…`), not a scheme.
  if (scheme != null && scheme.length > 1) {
    if (!_webSchemes.contains(scheme)) {
      return UnsupportedLink("$scheme: links can't be opened here.");
    }
    final uri = Uri.tryParse(raw);
    return uri == null
        ? const UnsupportedLink('This link is malformed.')
        : WebLink(uri);
  }
  if (scheme != null ||
      raw.startsWith(r'\\') ||
      (fromFile == null && raw.startsWith('//'))) {
    return const UnsupportedLink(
      "Paths on the computer's disk can't be opened; only workspace files can.",
    );
  }

  var path = raw;
  String? fragment;
  final hash = path.indexOf('#');
  if (hash >= 0) {
    fragment = path.substring(hash + 1);
    path = path.substring(0, hash);
  }
  final query = path.indexOf('?');
  if (query >= 0) path = path.substring(0, query);
  try {
    path = Uri.decodeFull(path);
  } on Object {
    // A stray `%` (ArgumentError) or bad UTF-8 (FormatException): not
    // percent-encoded after all, use it as written.
  }
  path = path.replaceAll(r'\', '/');

  int? start;
  int? end;
  final lines = fragment == null ? null : _lineFragment.firstMatch(fragment);
  if (lines != null) {
    start = int.parse(lines.group(1)!);
    end = lines.group(2) == null ? null : int.parse(lines.group(2)!);
  } else if (_lineSuffix.firstMatch(path) case final m?) {
    start = int.parse(m.group(1)!);
    end = m.group(2) == null ? null : int.parse(m.group(2)!);
    path = path.substring(0, m.start);
  }
  if (start != null && start < 1) start = 1;
  if (start != null && end != null && end < start) end = start;

  if (path.isEmpty) {
    // `#…` alone: a place in the same document.
    if (fromFile != null && start != null) {
      return FileLink(fromFile, startLine: start, endLine: end);
    }
    return const UnsupportedLink("Links to headings aren't supported yet.");
  }
  if (path.endsWith('/')) {
    return const UnsupportedLink("Links to folders aren't supported yet.");
  }

  final String root;
  final segments = <String>[];
  final List<String> link;
  if (fromFile != null) {
    final base = fromFile.split('/');
    root = base.first;
    if (!path.startsWith('/')) {
      segments.addAll(base.sublist(1, base.length - 1));
    }
    link = path.split('/');
  } else {
    if (roots.isEmpty) return const NeedsRoots();
    final parts = path.split('/').where((s) => s.isNotEmpty && s != '.');
    final first = parts.isEmpty ? null : parts.first;
    if (first != null && roots.contains(first)) {
      root = first;
      link = parts.skip(1).toList();
    } else {
      root = roots.first;
      link = parts.toList();
    }
  }
  for (final segment in link) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isEmpty) {
        return const UnsupportedLink('This link points outside the workspace.');
      }
      segments.removeLast();
    } else {
      segments.add(segment);
    }
  }
  if (segments.isEmpty) {
    return const UnsupportedLink("Links to folders aren't supported yet.");
  }
  return FileLink(
    [root, ...segments].join('/'),
    startLine: start,
    endLine: end,
  );
}
