import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/util/markdown_anchors.dart';

void main() {
  group('headingSlug', () {
    test('follows GitHub', () {
      expect(headingSlug('Getting Started'), 'getting-started');
      expect(headingSlug('What’s new in 1.2?'), 'whats-new-in-12');
      expect(headingSlug('`read_file` and **bold**'), 'read_file-and-bold');
      expect(headingSlug('_Emphasis_ here'), 'emphasis-here');
      expect(headingSlug('See [the docs](x.md)'), 'see-the-docs');
      expect(headingSlug('Ünïcode Café'), 'ünïcode-café');
      expect(headingSlug('A -- B'), 'a----b');
    });
  });

  group('splitAtHeadings', () {
    test('one section per heading, preamble first', () {
      final sections = splitAtHeadings(
        'Intro text\n\n# Title\nbody\n\n## Install ##\nsteps\n',
      );
      expect([for (final s in sections) s.slug], [null, 'title', 'install']);
      expect(sections[0].text, 'Intro text');
      expect(sections[1].text, '# Title\nbody');
      expect(sections[2].text, '## Install ##\nsteps');
    });

    test('no blank preamble, and every line is kept', () {
      const doc = '\n# A\none\n# B\ntwo';
      final sections = splitAtHeadings(doc);
      expect([for (final s in sections) s.slug], ['a', 'b']);
      expect(sections.map((s) => s.text).join('\n'), doc.trim());
    });

    test('headings inside fenced code are not headings', () {
      final sections = splitAtHeadings(
        '# Shell\n```sh\n# a comment\n~~~\n```\n# Next\n~~~~\n# x\n~~~~\n',
      );
      expect([for (final s in sections) s.slug], ['shell', 'next']);
    });

    test('#tags and indented code are not headings', () {
      final sections = splitAtHeadings('#tag\n    # code\n# Real');
      expect([for (final s in sections) s.slug], [null, 'real']);
    });

    test('duplicate headings are numbered', () {
      final sections = splitAtHeadings('# Usage\n# Usage\n# Usage');
      expect([for (final s in sections) s.slug], ['usage', 'usage-1', 'usage-2']);
    });
  });

  group('findSection', () {
    final sections = splitAtHeadings('# Getting Started\n# Café au lait');

    test('by slug, encoded slug, or heading text', () {
      expect(findSection(sections, 'getting-started'), 0);
      expect(findSection(sections, 'Getting-Started'), 0);
      expect(findSection(sections, 'Getting%20Started'), 0);
      expect(findSection(sections, 'caf%C3%A9-au-lait'), 1);
      expect(findSection(sections, 'missing'), isNull);
      expect(findSection(sections, '%'), isNull);
    });
  });
}
