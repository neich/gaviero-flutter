import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/ui/chat_screen.dart';
import 'package:gaviero_remote/src/ui/explorer_screen.dart';
import 'package:gaviero_remote/src/ui/file_view_screen.dart';
import 'package:gaviero_remote/src/ui/home_screen.dart';
import 'package:gaviero_remote/src/ui/shell_screen.dart';

import 'package:gaviero_remote/src/protocol/protocol.dart' show Role;

import 'every_tab_test.dart'
    show CapturingSocket, connected, env, msg, snapshot;

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

int _count(CapturingSocket socket, String type) =>
    socket.sent.where((f) => f['type'] == type).length;

HomeSection _shown(WidgetTester tester) => HomeSection
    .values[tester.widget<IndexedStack>(find.byType(IndexedStack)).index!];

Future<void> _open(WidgetTester tester, HomeSection section) async {
  await tester.tap(find.byKey(Key('section-${section.name}')));
  await tester.pump();
}

const _roots = {
  'path': '',
  'roots': [
    {'name': 'repo', 'path': 'repo', 'is_dir': true},
  ],
  'entries': <Object?>[],
  'truncated': false,
};

const _repo = {
  'path': 'repo',
  'roots': <Object?>[],
  'entries': [
    {'name': 'src', 'path': 'repo/src', 'is_dir': true},
    {'name': 'README.md', 'path': 'repo/README.md', 'is_dir': false},
  ],
  'truncated': false,
};

const _capabilities = ['file_browser', 'shell_sessions'];

void main() {
  testWidgets('sections open lazily and keep their state when switching', (
    tester,
  ) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: _capabilities),
    ))!;
    final replies = _Replies(socket);
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    expect(_shown(tester), HomeSection.conversations);
    expect(find.byType(ChatScreen), findsOneWidget);
    // Nothing is asked of the server for a section never opened.
    expect(find.byType(ExplorerScreen, skipOffstage: false), findsNothing);
    expect(_count(socket, 'list_directory'), 0);
    expect(_count(socket, 'request_terminals'), 0);

    await _open(tester, HomeSection.files);
    replies.reply('list_directory', _roots);
    await tester.pump();
    await tester.tap(find.text('repo'));
    await tester.pump();
    replies.reply('list_directory', _repo);
    await tester.pump();
    await tester.tap(find.text('README.md'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(FileViewScreen), findsOneWidget);
    // The section bar stays above the pushed file.
    expect(find.byKey(const Key('section-conversations')), findsOneWidget);

    await _open(tester, HomeSection.conversations);
    expect(_shown(tester), HomeSection.conversations);
    await _open(tester, HomeSection.files);
    expect(_shown(tester), HomeSection.files);
    expect(find.byType(FileViewScreen, skipOffstage: false), findsOneWidget);
    expect(_count(socket, 'list_directory'), 2);
    expect(_count(socket, 'read_file'), 1);

    // Back closes the file onto the same expanded tree, then returns to
    // Conversations.
    await tester.binding.handlePopRoute();
    await tester.pump();
    // The viewer's spinner never settles; outlast the exit transition.
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(FileViewScreen, skipOffstage: false), findsNothing);
    expect(find.text('src'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_shown(tester), HomeSection.conversations);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.connection.stop());
    controller.dispose();
  });

  testWidgets('a hidden shell section stops polling and keeps its tab', (
    tester,
  ) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: _capabilities),
    ))!;
    final replies = _Replies(socket);
    Map<String, Object?> shells(int id) => {
      'terminals': [
        {'id': 1, 'title': 'Bash', 'cwd': '/a', 'spawned': true},
        {'id': 2, 'title': 'Bash', 'cwd': '/b', 'spawned': true},
      ],
      'selected_id': id,
      'screen': {'text': 'screen $id', 'rows': 24, 'cols': 80},
    };
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await _open(tester, HomeSection.shells);
    replies.reply('request_terminals', shells(1));
    await tester.pump();
    await tester.tap(find.text('Bash · 2'));
    await tester.pump();
    replies.reply('request_terminals', shells(2));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'ls -la');
    expect(find.text('screen 2'), findsOneWidget);

    await _open(tester, HomeSection.conversations);
    final polls = _count(socket, 'request_terminals');
    await tester.pump(const Duration(seconds: 3));
    expect(_count(socket, 'request_terminals'), polls);

    await _open(tester, HomeSection.shells);
    expect(_count(socket, 'request_terminals'), polls + 1);
    final request = socket.sent.lastWhere(
      (f) => f['type'] == 'request_terminals',
    );
    expect((request['payload'] as Map)['terminal_id'], 2);
    expect(find.text('screen 2'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'ls -la',
    );
    expect(find.byType(ShellScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.connection.stop());
    controller.dispose();
  });

  testWidgets('a file link in chat opens the viewer in Files', (tester) async {
    final (controller, socket) = (await tester.runAsync(
      () => connected(capabilities: _capabilities),
    ))!;
    final replies = _Replies(socket);
    controller.state.applyEnvelope(
      env(
        snapshot(
          messages: [
            msg(10, 'See [the lib](crates/x.rs#L3).', role: Role.assistant),
          ],
          hasOlder: false,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
    await tester.tapOnText(find.textRange.ofSubstring('the lib'));
    await tester.pump();
    // Workspace-relative: the root labels are asked for first.
    final ask = socket.sent.lastWhere((f) => f['type'] == 'list_directory');
    expect(ask['payload'], isEmpty);
    replies.reply('list_directory', _roots);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(_shown(tester), HomeSection.files);
    final viewer = tester.widget<FileViewScreen>(find.byType(FileViewScreen));
    expect((viewer.path, viewer.startLine), ('repo/crates/x.rs', 3));
    expect(
      socket.sent.lastWhere((f) => f['type'] == 'read_file')['payload'],
      {'path': 'repo/crates/x.rs'},
    );

    // Back closes the viewer onto the tree.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(FileViewScreen, skipOffstage: false), findsNothing);
    expect(_shown(tester), HomeSection.files);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.connection.stop());
    controller.dispose();
  });

  testWidgets('opening a conversation from outside shows Conversations', (
    tester,
  ) async {
    final (controller, _) = (await tester.runAsync(
      () => connected(capabilities: _capabilities),
    ))!;
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await _open(tester, HomeSection.files);
    expect(_shown(tester), HomeSection.files);
    controller.conversationFocus.value++;
    await tester.pump();
    expect(_shown(tester), HomeSection.conversations);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.connection.stop());
    controller.dispose();
  });
}
