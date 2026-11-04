import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/ui/shell_screen.dart';

import 'package:gaviero_remote/src/state/controller.dart';

import 'every_tab_test.dart' show CapturingSocket, connected;

void main() {
  testWidgets('shell tabs target input and control keys at the selected PTY',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['shell_sessions']),
    ))!;
    var seq = 2;
    void reply(String type, Object? result) {
      final request = socket.sent.lastWhere((f) => f['type'] == type);
      socket.serverSend({
        'version': {'major': 1, 'minor': 1},
        'instance_id': 'i1', 'seq': seq++, 'revision': 1,
        'type': 'command_result',
        'payload': {
          'command_id': request['command_id'], 'status': 'completed',
          'result': ?result,
        },
      });
    }

    Map<String, Object?> shells(int id) => {
      'terminals': [
        {'id': 1, 'title': 'Bash', 'cwd': '/repo', 'spawned': true},
        {'id': 2, 'title': 'PowerShell', 'cwd': 'C:/repo', 'spawned': true},
      ],
      'selected_id': id,
      'screen': {'text': 'screen $id', 'rows': 24, 'cols': 80},
    };

    await tester.pumpWidget(MaterialApp(home: ShellScreen(controller: controller)));
    reply('request_terminals', shells(1));
    await tester.pump();
    expect(find.text('screen 1'), findsOneWidget);
    await tester.tap(find.text('PowerShell · 2'));
    await tester.pump();
    expect((socket.sent.last['payload'] as Map)['terminal_id'], 2);
    reply('request_terminals', shells(2));
    await tester.pump();
    expect(find.text('screen 2'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'echo café');
    await tester.tap(find.byTooltip('Enter'));
    await tester.pump();
    final input = socket.sent.lastWhere((f) => f['type'] == 'terminal_input');
    expect(input['payload'], {'terminal_id': 2, 'text': 'echo café\r'});
    reply('terminal_input', null);
    await tester.pump();
    await tester.tap(find.text('Ctrl+C'));
    await tester.pump();
    expect(socket.sent.lastWhere((f) => f['type'] == 'terminal_input')['payload'],
        {'terminal_id': 2, 'text': '\x03'});
    expect(socket.sent.where((f) => f['type'] == 'switch_conversation'), isEmpty);
    final count = socket.sent.where((f) => f['type'] == 'terminal_input').length;
    await tester.runAsync(() => controller.connection.stop());
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(socket.sent.where((f) => f['type'] == 'terminal_input').length, count);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('with workspace roots, tabs and prompts read relative paths',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['shell_sessions']),
    ))!;
    await tester.pumpWidget(MaterialApp(home: ShellScreen(controller: controller)));
    final sent = socket.sent.lastWhere((f) => f['type'] == 'request_terminals');
    socket.serverSend({
      'version': {'major': 1, 'minor': 1},
      'instance_id': 'i1', 'seq': 2, 'revision': 1,
      'type': 'command_result',
      'payload': {
        'command_id': sent['command_id'], 'status': 'completed',
        'result': {
          'terminals': [
            {'id': 1, 'title': 'pwsh', 'cwd': r'C:\w\repo\src', 'spawned': true},
            {'id': 2, 'title': 'pwsh', 'cwd': r'C:\w\repo', 'spawned': true},
          ],
          'selected_id': 1,
          'screen': {'text': r'PS C:\w\repo\src> ', 'rows': 24, 'cols': 80},
          'roots': [{'label': 'repo', 'path': r'C:\w\repo'}],
        },
      },
    });
    await tester.pump();
    expect(find.text(r'repo\src'), findsOneWidget);
    expect(find.text('repo'), findsOneWidget);
    expect(find.text(r'PS repo\src> '), findsOneWidget);
    expect(find.text(r'C:\w\repo\src'), findsNothing);
    // The toggle brings back the exact screen and the absolute cwd.
    await tester.tap(find.byKey(const Key('shell-full-paths')));
    await tester.pump();
    expect(find.text(r'PS C:\w\repo\src> '), findsOneWidget);
    expect(find.text(r'C:\w\repo\src'), findsOneWidget);
    await tester.runAsync(() => controller.connection.stop());
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('older servers show an update message and receive no shell commands',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(() => connected()))!;
    await tester.pumpWidget(MaterialApp(home: ShellScreen(controller: controller)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Update Gaviero'), findsOneWidget);
    expect(socket.sent.where((f) => f['type'] == 'request_terminals'), isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.connection.stop());
    controller.dispose();
  });

  /// A connected shell screen on one pwsh tab (id 2); `reply` answers the
  /// newest request of a type.
  Future<(RemoteController, CapturingSocket, void Function(String, Object?))>
      openShell(
      WidgetTester tester, List<String> capabilities) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: capabilities),
    ))!;
    var seq = 2;
    void reply(String type, Object? result) {
      final request = socket.sent.lastWhere((f) => f['type'] == type);
      socket.serverSend({
        'version': {'major': 1, 'minor': 7},
        'instance_id': 'i1', 'seq': seq++, 'revision': 1,
        'type': 'command_result',
        'payload': {
          'command_id': request['command_id'], 'status': 'completed',
          'result': ?result,
        },
      });
    }

    await tester.pumpWidget(MaterialApp(home: ShellScreen(controller: controller)));
    reply('request_terminals', {
      'terminals': [
        {'id': 2, 'title': 'pwsh', 'cwd': 'C:/repo', 'spawned': true},
      ],
      'selected_id': 2,
      'screen': {'text': 'PS C:/repo> ', 'rows': 24, 'cols': 80},
    });
    await tester.pump();
    return (controller, socket, reply);
  }

  TextEditingController box(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(const Key('shell-command'))).controller!;

  testWidgets('↑ fills the box from the shell history; nothing reaches the PTY until Enter',
      (tester) async {
    final (controller, socket, reply) = await openShell(
        tester, ['shell_sessions', 'shell_history']);
    int inputs() =>
        socket.sent.where((f) => f['type'] == 'terminal_input').length;

    await tester.tap(find.text('↑'));
    await tester.pump();
    final request = socket.sent
        .lastWhere((f) => f['type'] == 'request_terminals');
    expect(request['payload'], {'terminal_id': 2, 'history': 200});
    reply('request_terminals', {
      'terminals': [{'id': 2, 'title': 'pwsh', 'cwd': 'C:/repo', 'spawned': true}],
      'selected_id': 2,
      'history': ['git status', 'if (\$x) {\n  1\n}', 'cargo build --release'],
    });
    await tester.pump();
    await tester.pump();
    expect(box(tester).text, 'cargo build --release');
    expect(box(tester).selection.baseOffset, 21);
    // Multi-line entries are skipped: the box is one line.
    await tester.tap(find.text('↑'));
    await tester.pump();
    expect(box(tester).text, 'git status');
    expect(inputs(), 0);

    // Caret keys edit inside the box.
    await tester.tap(find.text('⇥'));
    await tester.pump();
    box(tester).value = box(tester).value.replaced(
        TextRange.collapsed(box(tester).selection.baseOffset), ' --short');
    await tester.tap(find.text('⇤'));
    await tester.pump();
    expect(box(tester).selection.baseOffset, 0);
    await tester.longPress(find.text('→'));
    await tester.pump();
    expect(box(tester).selection.baseOffset, 3);

    await tester.tap(find.byTooltip('Enter'));
    await tester.pump();
    expect(socket.sent
        .lastWhere((f) => f['type'] == 'terminal_input')['payload'],
        {'terminal_id': 2, 'text': 'git status --short\r'});
    reply('terminal_input', null);
    await tester.pump();
    expect(box(tester).text, isEmpty);

    // Ctrl+C still goes straight to the shell.
    await tester.tap(find.text('Ctrl+C'));
    await tester.pump();
    expect(socket.sent
        .lastWhere((f) => f['type'] == 'terminal_input')['payload'],
        {'terminal_id': 2, 'text': '\x03'});

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.connection.stop());
    controller.dispose();
  });

  testWidgets('without shell_history, ↑/↓ walk the commands sent from the phone',
      (tester) async {
    final (controller, socket, reply) = await openShell(tester, ['shell_sessions']);
    Future<void> run(String command) async {
      await tester.enterText(find.byKey(const Key('shell-command')), command);
      await tester.tap(find.byTooltip('Enter'));
      await tester.pump();
      reply('terminal_input', null);
      await tester.pump();
    }

    await run('git status');
    await run('git diff');
    final requests = socket.sent
        .where((f) => f['type'] == 'request_terminals').length;

    await tester.enterText(find.byKey(const Key('shell-command')), 'half');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(box(tester).text, 'git diff');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(box(tester).text, 'git status');
    await tester.tap(find.text('↓'));
    await tester.pump();
    await tester.tap(find.text('↓'));
    await tester.pump();
    expect(box(tester).text, 'half');
    // Recall never asks an older server for history.
    expect(socket.sent
        .where((f) => f['type'] == 'request_terminals' &&
            (f['payload'] as Map).containsKey('history')), isEmpty);
    expect(socket.sent
        .where((f) => f['type'] == 'request_terminals').length, requests);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.connection.stop());
    controller.dispose();
  });
}
