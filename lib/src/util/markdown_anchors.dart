/// Heading anchors in a Markdown document: `[Install](#install)` names the
/// `## Install` heading by its GitHub-style slug.
///
/// The preview is split at its headings so each section is its own widget
/// and a link can scroll to it; the renderer offers no handle on where a
/// heading lands inside one rich text.
library;

/// A run of the document: [slug] is the anchor of the heading that opens
/// it, null for the text before the first heading.
typedef MarkdownSection = ({String text, String? slug});

/// An ATX heading as the renderer reads it (`#`…`######`, then a space).
final _heading = RegExp(r'^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$');
final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');

/// [markdown] split before each heading outside fenced code. Blank text
/// before the first heading is dropped; duplicate slugs get `-1`, `-2`, …
/// as on GitHub.
List<MarkdownSection> splitAtHeadings(String markdown) {
  final sections = <MarkdownSection>[];
  final seen = <String, int>{};
  final buffer = StringBuffer();
  String? slug;
  String? fence;

  void flush() {
    final text = buffer.toString();
    buffer.clear();
    if (slug == null && text.trim().isEmpty) return;
    sections.add((text: text.trimRight(), slug: slug));
  }

  for (final line in markdown.split('\n')) {
    final marker = _fence.firstMatch(line)?.group(1);
    if (fence != null) {
      if (marker != null &&
          marker[0] == fence[0] &&
          marker.length >= fence.length &&
          line.trim() == marker) {
        fence = null;
      }
    } else if (marker != null) {
      fence = marker;
    } else if (_heading.firstMatch(line) case final m?) {
      flush();
      final base = headingSlug(m.group(2)!);
      final count = seen[base] ?? 0;
      seen[base] = count + 1;
      slug = count == 0 ? base : '$base-$count';
    }
    buffer
      ..write(line)
      ..write('\n');
  }
  flush();
  return sections;
}

final _link = RegExp(r'!?\[([^\]]*)\]\([^)]*\)');
final _tag = RegExp(r'<[^>]*>');
final _edgeUnderscore = RegExp(
  r'(?<![\p{L}\p{N}])_+|_+(?![\p{L}\p{N}])',
  unicode: true,
);
final _notSlug = RegExp(r'[^\p{L}\p{N}\p{M} _-]', unicode: true);

/// GitHub's anchor for a heading's text: link and emphasis markup dropped,
/// lower-cased, punctuation removed, each space a hyphen.
String headingSlug(String heading) => heading
    .replaceAllMapped(_link, (m) => m.group(1)!)
    .replaceAll(_tag, '')
    .replaceAll(_edgeUnderscore, '')
    .toLowerCase()
    .replaceAll(_notSlug, '')
    .trim()
    .replaceAll(' ', '-');

/// Index in [sections] of the heading [fragment] names (the part after `#`,
/// possibly percent-encoded), or null. An exact slug wins; otherwise the
/// fragment is compared as heading text, for hand-written `#My Section`.
int? findSection(List<MarkdownSection> sections, String fragment) {
  var wanted = fragment;
  try {
    wanted = Uri.decodeComponent(fragment);
  } on Object {
    // Not percent-encoded after all.
  }
  for (final candidate in {wanted, wanted.toLowerCase(), headingSlug(wanted)}) {
    if (candidate.isEmpty) continue;
    final index = sections.indexWhere((s) => s.slug == candidate);
    if (index >= 0) return index;
  }
  return null;
}
