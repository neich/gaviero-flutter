/// Reasoning blocks collapse behind a "Thinking…" header (the raw
/// `<think>` framing never reaches the screen) and long code lines wrap
/// instead of scrolling sideways.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/protocol.dart';
import 'package:gaviero_remote/src/ui/message_widgets.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: ListView(children: [child])),
    );

Message _assistant(String content, {List<CodeBlock> codeBlocks = const []}) =>
    Message(
      seq: 1,
      role: Role.assistant,
      content: content,
      truncated: false,
      toolCalls: const [],
      codeBlocks: codeBlocks,
    );

bool _anyTextContains(WidgetTester tester, String needle) => tester
    .widgetList<RichText>(find.byType(RichText))
    .any((w) => w.text.toPlainText().contains(needle));

void main() {
  testWidgets('a closed think block collapses to a gist and unfolds on tap',
      (tester) async {
    await tester.pumpWidget(_host(MessageBubble(
      message: _assistant(
          'Before.\n<think>\nLooking at the parser first.\nThen the lexer.\n'
          '</think>\nThe answer.'),
    )));

    expect(_anyTextContains(tester, '<think>'), isFalse);
    expect(_anyTextContains(tester, '</think>'), isFalse);
    expect(find.text('Thought'), findsOneWidget);
    expect(_anyTextContains(tester, 'Before.'), isTrue);
    expect(_anyTextContains(tester, 'The answer.'), isTrue);
    // Collapsed: only the one-line gist, flattened.
    expect(find.text('Looking at the parser first. Then the lexer.'),
        findsOneWidget);

    await tester.tap(find.text('Thought'));
    await tester.pump();
    expect(find.text('Looking at the parser first. Then the lexer.'),
        findsNothing);
    expect(_anyTextContains(tester, 'Then the lexer.'), isTrue);
  });

  testWidgets('a streaming think block shows a live Thinking… header',
      (tester) async {
    await tester.pumpWidget(_host(const StreamingBubble(
      text: 'Answer.\n<think>\nfirst step\nsecond step',
      status: null,
      toolCalls: [],
    )));

    expect(find.text('Thinking…'), findsOneWidget);
    expect(_anyTextContains(tester, '<think>'), isFalse);
    expect(find.text('first step second step'), findsOneWidget);
  });

  testWidgets('a server code block inside a think block stays folded',
      (tester) async {
    const content = '<think>\n```rust\nfn main() {}\n```\n</think>\nDone.';
    final start = content.indexOf('```');
    final end = content.lastIndexOf('```') + 3;
    await tester.pumpWidget(_host(MessageBubble(
      message: _assistant(content, codeBlocks: [
        CodeBlock(
            startByte: start,
            endByte: end,
            language: 'rust',
            truncated: false,
            spans: const []),
      ]),
    )));

    expect(find.byType(CodeBlockView), findsNothing);
    expect(find.text('Thought'), findsOneWidget);
    expect(_anyTextContains(tester, 'Done.'), isTrue);
  });

  testWidgets('long code lines wrap instead of scrolling sideways',
      (tester) async {
    final line = 'let value = ${List.filled(60, 'segment').join(' + ')};';
    final content = '```rust\n$line\n```';
    await tester.pumpWidget(_host(MessageBubble(
      message: _assistant(content, codeBlocks: [
        CodeBlock(
            startByte: 0,
            endByte: content.length,
            language: 'rust',
            truncated: false,
            spans: const []),
      ]),
    )));

    expect(find.byType(CodeBlockView), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(CodeBlockView),
            matching: find.byType(SingleChildScrollView)),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('streamed fences wrap too', (tester) async {
    final line = List.filled(80, 'x').join('_');
    await tester.pumpWidget(_host(StreamingBubble(
      text: 'Here:\n```\n$line\n```\n',
      status: null,
      toolCalls: const [],
    )));

    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
