/// Display-only shortening of shell paths against the workspace roots the
/// server sends with `request_terminals` (`roots: [{label, path}]`).
/// `C:\work\gaviero\crates` under root `gaviero` reads `gaviero\crates`.
library;

final class ShellRoot {
  final String label;
  final String path;

  const ShellRoot({required this.label, required this.path});

  /// Absent or malformed `roots` (older servers) yield an empty list.
  static List<ShellRoot> listFromJson(Object? json) => [
        if (json is List)
          for (final r in json)
            if (r is Map &&
                r['label'] is String &&
                r['path'] is String &&
                (r['path'] as String).isNotEmpty)
              ShellRoot(label: r['label'] as String, path: r['path'] as String),
      ];
}

final class ShellPaths {
  /// Longest path first, so a nested root wins over its parent.
  final List<ShellRoot> roots;
  final List<(RegExp, String)> _patterns;

  ShellPaths(List<ShellRoot> roots)
      : roots = [...roots]..sort((a, b) => b.path.length - a.path.length),
        _patterns = [] {
    for (final root in this.roots) {
      for (final variant in _variants(_trimSeparators(root.path))) {
        _patterns.add((
          RegExp(
            // Only a whole path segment: `…\gaviero` must not eat the front
            // of `…\gaviero-flutter`.
            '${RegExp.escape(variant)}(?=[\\\\/\\s>)\\]"\':;,]|\$)',
            caseSensitive: !_isWindows(root.path),
            multiLine: true,
          ),
          root.label,
        ));
      }
    }
  }

  bool get isEmpty => roots.isEmpty;

  /// [path] relative to the longest matching root, prefixed by its label,
  /// keeping the path's own separators; `null` when no root contains it.
  String? relative(String path) {
    for (final root in roots) {
      final base = _trimSeparators(root.path);
      final windows = _isWindows(base);
      final p = windows ? path.toLowerCase() : path;
      final b = windows ? base.toLowerCase() : base;
      if (p == b) return root.label;
      if (p.length > b.length &&
          p.startsWith(b) &&
          _isSeparator(path[b.length])) {
        return '${root.label}${path.substring(b.length)}';
      }
    }
    return null;
  }

  /// Every root path in [text] (native, `/`-separated, and MSYS `/c/…`
  /// spellings) replaced by its label.
  String shorten(String text) {
    var out = text;
    for (final (pattern, label) in _patterns) {
      out = out.replaceAll(pattern, label);
    }
    return out;
  }

  static bool _isSeparator(String c) => c == '/' || c == '\\';

  static bool _isWindows(String path) =>
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');

  static String _trimSeparators(String path) {
    var end = path.length;
    // Keep a bare drive or filesystem root intact.
    while (end > 1 && _isSeparator(path[end - 1]) && path[end - 2] != ':') {
      end--;
    }
    return path.substring(0, end);
  }

  /// The spellings a shell prompt may use for [path].
  static Set<String> _variants(String path) {
    final variants = {path};
    if (_isWindows(path)) {
      final forward = path.replaceAll('\\', '/');
      variants.add(forward);
      variants.add(path.replaceAll('/', '\\'));
      final drive = RegExp(r'^([A-Za-z]):/').firstMatch(forward);
      if (drive != null) {
        // Git Bash / MSYS: C:\x → /c/x.
        variants.add(
            '/${drive.group(1)!.toLowerCase()}/${forward.substring(3)}');
      }
    }
    return variants;
  }
}
