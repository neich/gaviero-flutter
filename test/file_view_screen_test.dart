import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/ui/file_view_screen.dart';
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
    expect(raw.data, startsWith('# Title'));
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
}
