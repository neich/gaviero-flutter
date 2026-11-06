import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/ui/file_view_screen.dart';
import 'package:gaviero_remote/src/ui/link_actions.dart';
import 'package:gaviero_remote/src/ui/message_widgets.dart';

import 'every_tab_test.dart' show CapturingSocket, connected;

/// Answers the most recent `read_file` request with a `command_result`.
final class _Replies {
  final CapturingSocket socket;
  int _seq = 2;

  _Replies(this.socket);

  void file(Object result) {
    final request = socket.sent.lastWhere((f) => f['type'] == 'read_file');
    socket.serverSend({
      'version': {'major': 1, 'minor': 3},
      'instance_id': 'i1',
      'seq': _seq++,
      'revision': 1,
      'type': 'command_result',
      'payload': {
        'command_id': request['command_id'],
        'status': 'completed',
        'result': result,
      },
    });
  }
}

Map<String, Object?> _content({
  String path = 'repo/src/main.rs',
  String language = 'rust',
  required String content,
  int? bytes,
  bool truncated = false,
  List<String> classes = const [],
  List<List<int>> spans = const [],
  bool spansTruncated = false,
}) => {
  'path': path,
  'viewable': true,
  'language': language,
  'bytes': bytes ?? utf8.encode(content).length,
  'truncated': truncated,
  'content': content,
  'classes': classes,
  'spans': spans,
  'spans_truncated': spansTruncated,
};

Future<void> _teardown(WidgetTester tester, dynamic controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => controller.connection.stop());
  controller.dispose();
}

void main() {
  testWidgets('renders rust content with classed runs', (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['file_browser']),
    ))!;
    final replies = _Replies(socket);
    await tester.pumpWidget(
      MaterialApp(
        home: FileViewScreen(
          controller: controller,
          path: 'repo/src/main.rs',
          name: 'main.rs',
        ),
      ),
    );
    await tester.pump();
    replies.file(
      _content(
        content: 'fn main() {}',
        classes: ['keyword', 'function'],
        spans: [
          [0, 2, 0],
          [3, 7, 1],
        ],
      ),
    );
    await tester.pump();

    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    expect(selectable.textSpan!.toPlainText(), 'fn main() {}');
    expect(find.byType(SelectableText), findsOneWidget);
    await _teardown(tester, controller);
  });

  testWidgets('markdown opens in preview and toggles to raw', (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['file_browser']),
    ))!;
    final replies = _Replies(socket);
    await tester.pumpWidget(
      MaterialApp(
        home: FileViewScreen(
          controller: controller,
          path: 'repo/README.md',
          name: 'README.md',
        ),
      ),
    );
    await tester.pump();
    replies.file(
      _content(
        path: 'repo/README.md',
        language: 'markdown',
        content: '# Title\n\nbody',
      ),
    );
    await tester.pump();
    expect(find.byType(MarkdownText), findsOneWidget);

    await tester.tap(find.text('Raw'));
    await tester.pump();
    final raw = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(raw.textSpan!.toPlainText(), startsWith('# Title'));
    expect(find.byType(MarkdownText), findsNothing);

    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(find.byType(MarkdownText), findsOneWidget);
    await _teardown(tester, controller);
  });

  testWidgets('binary and truncated files explain themselves', (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['file_browser']),
    ))!;
    final replies = _Replies(socket);

    await tester.pumpWidget(
      MaterialApp(
        home: FileViewScreen(
          controller: controller,
          path: 'repo/logo.png',
          key: const ValueKey('logo'),
          name: 'logo.png',
        ),
      ),
    );
    await tester.pump();
    replies.file({
      'path': 'repo/logo.png',
      'viewable': false,
      'reason': 'binary',
      'bytes': 4096,
    });
    await tester.pump();
    expect(find.textContaining('Binary file'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: FileViewScreen(
          controller: controller,
          path: 'repo/big.rs',
          key: const ValueKey('big'),
          name: 'big.rs',
        ),
      ),
    );
    await tester.pump();
    replies.file(
      _content(
        path: 'repo/big.rs',
        content: 'x',
        bytes: 120000,
        truncated: true,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Showing the first'), findsOneWidget);

    // Truncated with a tiny body must not crash either.
    await tester.pumpWidget(
      MaterialApp(
        home: FileViewScreen(
          controller: controller,
          path: 'repo/tiny.rs',
          key: const ValueKey('tiny'),
          name: 'tiny.rs',
        ),
      ),
    );
    await tester.pump();
    replies.file(
      _content(
        path: 'repo/tiny.rs',
        content: 'abc',
        bytes: 90000,
        truncated: true,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await _teardown(tester, controller);
  });

  testWidgets('non-ASCII offsets render correctly', (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['file_browser']),
    ))!;
    final replies = _Replies(socket);
    const content = 'let café = "✓";';
    final start = utf8.encode('let ').length;
    final end = start + utf8.encode('café').length;

    await tester.pumpWidget(
      MaterialApp(
        home: FileViewScreen(
          controller: controller,
          path: 'repo/x.rs',
          name: 'x.rs',
        ),
      ),
    );
    await tester.pump();
    replies.file(
      _content(
        path: 'repo/x.rs',
        content: content,
        classes: ['variable'],
        spans: [
          [start, end, 0],
        ],
      ),
    );
    await tester.pump();

    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    expect(selectable.textSpan!.toPlainText(), content);
    expect(tester.takeException(), isNull);
    await _teardown(tester, controller);
  });

  group('links', () {
    late List<Uri> launched;
    late Future<bool> Function(Uri) original;
    setUp(() {
      launched = [];
      original = openExternalUrl;
      openExternalUrl = (uri) async {
        launched.add(uri);
        return true;
      };
    });
    tearDown(() => openExternalUrl = original);

    Future<(dynamic, CapturingSocket, _Replies)> openDoc(
      WidgetTester tester,
      String content,
    ) async {
      final (controller, socket) = (await tester.runAsync(
        () => connected(capabilities: ['file_browser']),
      ))!;
      final replies = _Replies(socket);
      await tester.pumpWidget(
        MaterialApp(
          home: FileViewScreen(
            controller: controller,
            path: 'repo/docs/guide.md',
            name: 'guide.md',
          ),
        ),
      );
      await tester.pump();
      replies.file(
        _content(
          path: 'repo/docs/guide.md',
          language: 'markdown',
          content: content,
        ),
      );
      await tester.pump();
      return (controller, socket, replies);
    }

    testWidgets('a relative link opens the target file in a new viewer', (
      tester,
    ) async {
      final (controller, socket, _) = await openDoc(
        tester,
        'See [the setup](../src/lib.rs#L2) first.',
      );
      await tester.tapOnText(find.textRange.ofSubstring('the setup'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final read = socket.sent.lastWhere((f) => f['type'] == 'read_file');
      expect(read['payload'], {'path': 'repo/src/lib.rs'});
      final viewer = tester.widget<FileViewScreen>(
        find.byType(FileViewScreen).last,
      );
      expect((viewer.path, viewer.name, viewer.startLine), (
        'repo/src/lib.rs',
        'lib.rs',
        2,
      ));
      expect(launched, isEmpty);
      await _teardown(tester, controller);
    });

    testWidgets('web links go to the phone, never to the desktop', (
      tester,
    ) async {
      final (controller, socket, _) = await openDoc(
        tester,
        'Read [the docs](https://example.com/docs) or https://x.dev/a now.',
      );
      final reads = socket.sent.where((f) => f['type'] == 'read_file').length;
      await tester.tapOnText(find.textRange.ofSubstring('the docs'));
      await tester.pump();
      await tester.tapOnText(find.textRange.ofSubstring('https://x.dev/a'));
      await tester.pump();
      expect(launched, [
        Uri.parse('https://example.com/docs'),
        Uri.parse('https://x.dev/a'),
      ]);
      expect(socket.sent.where((f) => f['type'] == 'read_file').length, reads);
      await _teardown(tester, controller);
    });

    testWidgets('a link that leaves the workspace explains itself', (
      tester,
    ) async {
      final (controller, socket, _) = await openDoc(
        tester,
        'Not [here](../../../etc/passwd).',
      );
      final reads = socket.sent.where((f) => f['type'] == 'read_file').length;
      await tester.tapOnText(find.textRange.ofSubstring('here'));
      await tester.pump();
      expect(find.textContaining('outside the workspace'), findsOneWidget);
      expect(socket.sent.where((f) => f['type'] == 'read_file').length, reads);
      await _teardown(tester, controller);
    });

    testWidgets('#L… in the same document marks the lines in Raw', (
      tester,
    ) async {
      final (controller, _, _) = await openDoc(
        tester,
        'Jump to [line two](#L2).\nsecond\nthird',
      );
      await tester.tapOnText(find.textRange.ofSubstring('line two'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(MarkdownText), findsNothing);
      final raw = tester.widget<SelectableText>(find.byType(SelectableText));
      final marked = [
        for (final span in raw.textSpan!.children!.cast<TextSpan>())
          if (span.style?.backgroundColor != null) span.text,
      ];
      expect(marked, ['second\n']);
      await _teardown(tester, controller);
    });
  });

  testWidgets('a line target scrolls the code to that line and marks it', (
    tester,
  ) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['file_browser']),
    ))!;
    final replies = _Replies(socket);
    await tester.pumpWidget(
      MaterialApp(
        home: FileViewScreen(
          controller: controller,
          path: 'repo/src/main.rs',
          name: 'main.rs',
          startLine: 150,
          endLine: 151,
        ),
      ),
    );
    await tester.pump();
    final content = [for (var i = 1; i <= 300; i++) 'let line_$i = $i;'].join(
      '\n',
    );
    replies.file(
      _content(
        content: content,
        classes: ['keyword'],
        // A classed run spanning the marked lines: it must be split.
        spans: [
          [0, 3, 0],
          [content.indexOf('line_150'), content.indexOf('line_152'), 0],
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.pixels, greaterThan(0));
    final raw = tester.widget<SelectableText>(find.byType(SelectableText));
    final spans = raw.textSpan!.children!.cast<TextSpan>();
    final marked = [
      for (final span in spans)
        if (span.style?.backgroundColor != null) span.text,
    ];
    expect(marked.join(), 'let line_150 = 150;\nlet line_151 = 151;\n');
    // The classed run is split at the line ends, and keeps its colour.
    expect(
      spans.firstWhere((s) => s.text == 'line_150 = 150;\n').style?.color,
      isNotNull,
    );
    expect(raw.textSpan!.toPlainText(), content);
    await _teardown(tester, controller);
  });
}
