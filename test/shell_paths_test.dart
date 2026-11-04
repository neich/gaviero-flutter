import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/ui/shell_paths.dart';

void main() {
  final windows = ShellPaths([
    const ShellRoot(label: 'gaviero', path: r'C:\Users\me\git\gaviero\gaviero'),
    const ShellRoot(
        label: 'gaviero-flutter', path: r'C:\Users\me\git\gaviero\gaviero-flutter'),
  ]);

  test('roots parse from the request_terminals result, tolerating junk', () {
    expect(ShellRoot.listFromJson(null), isEmpty);
    expect(ShellRoot.listFromJson('x'), isEmpty);
    final roots = ShellRoot.listFromJson([
      {'label': 'a', 'path': '/w/a'},
      {'label': 'b'},
      {'label': 'c', 'path': ''},
    ]);
    expect(roots.map((r) => r.label), ['a']);
  });

  test('relative names a cwd by root label, keeping its separators', () {
    expect(windows.relative(r'C:\Users\me\git\gaviero\gaviero'), 'gaviero');
    expect(windows.relative(r'C:\Users\me\git\gaviero\gaviero\crates\core'),
        r'gaviero\crates\core');
    expect(windows.relative(r'c:\users\me\git\gaviero\gaviero-flutter\lib'),
        r'gaviero-flutter\lib');
    expect(windows.relative(r'C:\Users\me\git\gaviero'), isNull);
    expect(windows.relative(r'C:\Users\me\git\gaviero\gaviero2'), isNull);
  });

  test('a nested root wins over its parent', () {
    final nested = ShellPaths([
      const ShellRoot(label: 'outer', path: '/w'),
      const ShellRoot(label: 'inner', path: '/w/sub/'),
    ]);
    expect(nested.relative('/w/sub/x'), 'inner/x');
    expect(nested.relative('/w/other'), 'outer/other');
    expect(nested.shorten(r'$ cd /w/sub/x && ls /w/y'), r'$ cd inner/x && ls outer/y');
  });

  test('shorten rewrites prompt paths in every spelling', () {
    expect(
      windows.shorten('PS C:\\Users\\me\\git\\gaviero\\gaviero\\crates> ls\n'
          'PS C:\\Users\\me\\git\\gaviero\\gaviero-flutter> '),
      'PS gaviero\\crates> ls\nPS gaviero-flutter> ',
    );
    expect(windows.shorten('me@pc MINGW64 /c/Users/me/git/gaviero/gaviero (main)'),
        'me@pc MINGW64 gaviero (main)');
    expect(windows.shorten('cd C:/Users/me/git/gaviero/gaviero/lib'),
        'cd gaviero/lib');
  });

  test('shorten leaves look-alike paths alone', () {
    expect(windows.shorten(r'C:\Users\me\git\gaviero\gaviero2\x'),
        r'C:\Users\me\git\gaviero\gaviero2\x');
    expect(windows.shorten(r'C:\Users\me\git\gaviero'), r'C:\Users\me\git\gaviero');
  });

  test('POSIX roots match case-sensitively', () {
    final posix = ShellPaths([const ShellRoot(label: 'repo', path: '/home/me/repo')]);
    expect(posix.shorten('me@box:/home/me/repo/src\$ '), 'me@box:repo/src\$ ');
    expect(posix.shorten('/home/me/Repo/src'), '/home/me/Repo/src');
  });
}
