import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/state/app_state.dart';
import 'package:gaviero_remote/src/state/controller.dart';
import 'package:gaviero_remote/src/transport/connection.dart';
import 'package:gaviero_remote/src/ui/explorer_screen.dart';
import 'package:gaviero_remote/src/ui/file_view_screen.dart';

import 'every_tab_test.dart' show CapturingSocket, connected;
import 'support/relay_machine.dart';

Map<String, Object?> _hello() => {
  'version': {'major': 1, 'minor': 1},
  'instance_id': 'i1',
  'seq': 1,
  'revision': 1,
  'type': 'hello',
  'payload': {
    'protocol_version': {'major': 1, 'minor': 1},
    'instance_id': 'i1',
    'tui_version': '0.1.0',
    'workspace': {'id': 'w', 'display_name': 'w'},
    'capabilities': ['file_browser'],
    'confirm_required': <String>[],
    'allowed_slash_commands': <String>[],
    'limits': {
      'max_frame_bytes': 262144,
      'max_prompt_bytes': 131072,
      'command_rate_per_second': 10,
    },
  },
};

/// Answers the most recent request of `type` with a `command_result`.
final class _Replies {
  final CapturingSocket socket;
  int _seq = 2;

  _Replies(this.socket);

  void reply(String type, Object result) {
    final request = socket.sent.lastWhere((f) => f['type'] == type);
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

Map<String, Object?> _roots() => {
  'path': '',
  'roots': [
    {'name': 'repo', 'path': 'repo', 'is_dir': true},
  ],
  'entries': <Object?>[],
  'truncated': false,
};

Map<String, Object?> _repoListing() => {
  'path': 'repo',
  'roots': <Object?>[],
  'entries': [
    {'name': 'src', 'path': 'repo/src', 'is_dir': true},
    {
      'name': 'README.md',
      'path': 'repo/README.md',
      'is_dir': false,
      'size': 12,
    },
  ],
  'truncated': false,
};

Future<void> _teardown(WidgetTester tester, dynamic controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => controller.connection.stop());
  controller.dispose();
}

void main() {
  testWidgets('browses roots, expands a directory, and opens a file', (
    tester,
  ) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['file_browser']),
    ))!;
    final replies = _Replies(socket);

    await tester.pumpWidget(
      MaterialApp(home: ExplorerScreen(controller: controller)),
    );
    await tester.pump();
    replies.reply('list_directory', _roots());
    await tester.pump();
    expect(find.text('repo'), findsOneWidget);

    await tester.tap(find.text('repo'));
    await tester.pump();
    expect((socket.sent.last['payload'] as Map)['path'], 'repo');
    replies.reply('list_directory', _repoListing());
    await tester.pump();
    expect(find.text('src'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('12 B'), findsOneWidget);

    await tester.tap(find.text('README.md'));
    await tester.pump();
    // MaterialPageRoute runs a transition; the viewer's loading spinner never
    // settles, so advance the animation instead of pumpAndSettle().
    await tester.pump(const Duration(milliseconds: 400));
    final read = socket.sent.lastWhere((f) => f['type'] == 'read_file');
    expect(read['payload'], {'path': 'repo/README.md'});
    expect(find.byType(FileViewScreen), findsOneWidget);

    await _teardown(tester, controller);
  });

  testWidgets('older servers show an update message and receive no requests', (
    tester,
  ) async {
    final (controller, socket) = (await tester.runAsync(() => connected()))!;
    await tester.pumpWidget(
      MaterialApp(home: ExplorerScreen(controller: controller)),
    );
    await tester.pump();
    expect(find.textContaining('Update Gaviero'), findsOneWidget);
    expect(socket.sent.where((f) => f['type'] == 'list_directory'), isEmpty);
    await _teardown(tester, controller);
  });

  testWidgets('disconnect clears the tree and sends nothing', (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['file_browser']),
    ))!;
    final replies = _Replies(socket);
    await tester.pumpWidget(
      MaterialApp(home: ExplorerScreen(controller: controller)),
    );
    await tester.pump();
    replies.reply('list_directory', _roots());
    await tester.pump();
    expect(find.byKey(const ValueKey('explorer:repo')), findsOneWidget);

    final sent = socket.sent.where((f) => f['type'] == 'list_directory').length;
    await tester.runAsync(() => controller.connection.stop());
    await tester.pump();
    expect(find.byKey(const ValueKey('explorer:repo')), findsNothing);
    expect(
      socket.sent.where((f) => f['type'] == 'list_directory').length,
      sent,
    );

    await _teardown(tester, controller);
  });

  testWidgets('a reconnect reopens the folders that were open', (
    tester,
  ) async {
    final sockets = [CapturingSocket(), CapturingSocket()];
    var next = 0;
    final controller = RemoteController(
      connection: RemoteConnection(
        connector: (url, token) async => sockets[next++],
      ),
      state: AppState(),
    );
    Future<void> start(CapturingSocket socket) async {
      await controller.connection.start(
        Uri.parse('wss://h/v1/ws'),
        't',
        tlsCa: testTlsCa,
        relayHost: testRelayHost,
      );
      socket.serverSend(_hello());
      await Future<void>.delayed(Duration.zero);
    }

    await tester.runAsync(() => start(sockets[0]));
    var replies = _Replies(sockets[0]);
    await tester.pumpWidget(
      MaterialApp(home: ExplorerScreen(controller: controller)),
    );
    await tester.pump();
    replies.reply('list_directory', _roots());
    await tester.pump();
    await tester.tap(find.text('repo'));
    await tester.pump();
    replies.reply('list_directory', _repoListing());
    await tester.pump();
    expect(find.text('src'), findsOneWidget);

    await tester.runAsync(() => controller.connection.stop());
    await tester.pump();
    expect(find.text('src'), findsNothing);

    // The reconnect (and so the explorer's requests) runs in the real async
    // zone: answer there too.
    await tester.runAsync(() => start(sockets[1]));
    replies = _Replies(sockets[1]);
    Future<void> answer(Map<String, Object?> listing) =>
        tester.runAsync(() async {
          replies.reply('list_directory', listing);
          await Future<void>.delayed(Duration.zero);
        });
    await answer(_roots());
    await tester.pump();
    expect(find.text('repo'), findsOneWidget);
    final reopen = sockets[1].sent.lastWhere(
      (f) => f['type'] == 'list_directory',
    );
    expect((reopen['payload'] as Map)['path'], 'repo');
    await answer(_repoListing());
    await tester.pump();
    expect(find.text('src'), findsOneWidget);

    await _teardown(tester, controller);
  });

  testWidgets('a malformed listing does not crash', (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: ['file_browser']),
    ))!;
    final replies = _Replies(socket);
    await tester.pumpWidget(
      MaterialApp(home: ExplorerScreen(controller: controller)),
    );
    await tester.pump();
    replies.reply('list_directory', {'path': '', 'roots': [], 'entries': []});
    await tester.pump();
    expect(tester.takeException(), isNull);
    await _teardown(tester, controller);
  });
}
