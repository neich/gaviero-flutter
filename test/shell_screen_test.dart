import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/ui/shell_screen.dart';

import 'every_tab_test.dart' show connected;

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
          if (result != null) 'result': result,
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
}
