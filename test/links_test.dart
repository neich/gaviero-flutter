import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/util/links.dart';

const _doc = 'repo/docs/guide/intro.md';

FileLink _file(LinkTarget target) {
  expect(target, isA<FileLink>());
  return target as FileLink;
}

String _reason(LinkTarget target) {
  expect(target, isA<UnsupportedLink>());
  return (target as UnsupportedLink).reason;
}

void main() {
  group('web links', () {
    test('http, https and mailto open externally', () {
      for (final href in [
        'https://example.com/a?b=1#c',
        'HTTP://example.com',
        'mailto:me@example.com',
        '<https://example.com/x>',
      ]) {
        expect(resolveLink(href, fromFile: _doc), isA<WebLink>(), reason: href);
      }
      expect(
        (resolveLink('https://example.com/a#c') as WebLink).uri.fragment,
        'c',
      );
    });

    test('other schemes and disk paths are refused', () {
      expect(_reason(resolveLink('ftp://x/y')), contains('ftp:'));
      expect(_reason(resolveLink('file:///etc/passwd')), contains('file:'));
      expect(_reason(resolveLink(r'C:\Users\me\x.rs')), contains('disk'));
      expect(_reason(resolveLink(r'\\server\share\x')), contains('disk'));
      expect(_reason(resolveLink('//host/x', roots: ['repo'])), contains('disk'));
    });
  });

  group('relative to the open file', () {
    test('resolves against its folder', () {
      expect(_file(resolveLink('setup.md', fromFile: _doc)).path,
          'repo/docs/guide/setup.md');
      expect(_file(resolveLink('./a/b.md', fromFile: _doc)).path,
          'repo/docs/guide/a/b.md');
      expect(_file(resolveLink('../../README.md', fromFile: _doc)).path,
          'repo/README.md');
    });

    test('a leading slash is the root of the same workspace folder', () {
      expect(_file(resolveLink('/src/main.rs', fromFile: _doc)).path,
          'repo/src/main.rs');
    });

    test('cannot climb out of the workspace folder', () {
      expect(_reason(resolveLink('../../../x.md', fromFile: _doc)),
          contains('outside'));
      expect(_reason(resolveLink('/../x.md', fromFile: _doc)),
          contains('outside'));
    });

    test('percent-encoding, queries and backslashes', () {
      expect(_file(resolveLink('my%20notes.md', fromFile: _doc)).path,
          'repo/docs/guide/my notes.md');
      expect(_file(resolveLink('a.md?raw=1', fromFile: _doc)).path,
          'repo/docs/guide/a.md');
      expect(_file(resolveLink(r'..\b.md', fromFile: _doc)).path,
          'repo/docs/b.md');
      expect(_file(resolveLink('100%.md', fromFile: _doc)).path,
          'repo/docs/guide/100%.md');
    });
  });

  group('line targets', () {
    test('#L42 and #L10-L20', () {
      final one = _file(resolveLink('../x.rs#L42', fromFile: _doc));
      expect((one.path, one.startLine, one.endLine), ('repo/docs/x.rs', 42, null));
      final range = _file(resolveLink('x.rs#L10-L20', fromFile: _doc));
      expect((range.startLine, range.endLine), (10, 20));
      final bare = _file(resolveLink('x.rs#L10-20', fromFile: _doc));
      expect((bare.startLine, bare.endLine), (10, 20));
    });

    test('path:line suffix', () {
      final link = _file(resolveLink('/src/lib.rs:7', fromFile: _doc));
      expect((link.path, link.startLine), ('repo/src/lib.rs', 7));
      final range = _file(resolveLink('/src/lib.rs:7-9', fromFile: _doc));
      expect((range.startLine, range.endLine), (7, 9));
    });

    test('an inverted range collapses to its start', () {
      final link = _file(resolveLink('x.rs#L9-L3', fromFile: _doc));
      expect((link.startLine, link.endLine), (9, 9));
    });

    test('#L… alone targets the same file', () {
      final link = _file(resolveLink('#L5', fromFile: _doc));
      expect((link.path, link.startLine), (_doc, 5));
    });

    test('heading anchors carry the fragment', () {
      final link = _file(resolveLink('setup.md#install', fromFile: _doc));
      expect((link.path, link.startLine, link.anchor),
          ('repo/docs/guide/setup.md', null, 'install'));
      final here = _file(resolveLink('#getting-started', fromFile: _doc));
      expect((here.path, here.anchor), (_doc, 'getting-started'));
      final lines = _file(resolveLink('#L5', fromFile: _doc));
      expect(lines.anchor, isNull);
    });

    test('a bare # is the top of the same document', () {
      final link = _file(resolveLink('#', fromFile: _doc));
      expect((link.path, link.startLine, link.anchor), (_doc, null, null));
    });

    test('a heading link in chat has no document to look in', () {
      expect(_reason(resolveLink('#install', roots: ['repo'])),
          contains('inside a document'));
      final link = _file(resolveLink('README.md#install', roots: ['repo']));
      expect((link.path, link.anchor), ('repo/README.md', 'install'));
    });
  });

  test('folder links are not supported yet', () {
    expect(_reason(resolveLink('../', fromFile: _doc)), contains('folders'));
    expect(_reason(resolveLink('sub/', fromFile: _doc)), contains('folders'));
  });

  group('from chat (workspace-relative)', () {
    test('needs the root labels first', () {
      expect(resolveLink('src/main.rs'), isA<NeedsRoots>());
      expect(resolveLink('https://x.dev'), isA<WebLink>());
    });

    test('a first segment naming a folder picks it, else the first folder', () {
      const roots = ['gaviero', 'gaviero-flutter'];
      expect(_file(resolveLink('gaviero-flutter/lib/main.dart', roots: roots))
          .path, 'gaviero-flutter/lib/main.dart');
      expect(_file(resolveLink('crates/x.rs:12', roots: roots)).path,
          'gaviero/crates/x.rs');
      expect(_file(resolveLink('./crates/x.rs', roots: roots)).path,
          'gaviero/crates/x.rs');
      expect(_file(resolveLink('/crates/x.rs', roots: roots)).path,
          'gaviero/crates/x.rs');
      expect(_reason(resolveLink('../x.rs', roots: roots)), contains('outside'));
    });
  });
}
