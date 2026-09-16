/// B8 verification (machine-verifiable part): the chip row is built from
/// `hello.allowed_slash_commands` (a command not in the allow-list is
/// absent entirely), confirm-gated commands raise a dialog and send
/// `confirmed: true`, argument-taking chips prefill, and
/// `slash_not_allowed` renders as a calm inline notice. `@` completion asks
/// only a `file_completions` server, drops stale replies, and inserts
/// `@<path> ` on tap.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/state/app_state.dart';
import 'package:gaviero_remote/src/state/controller.dart';
import 'package:gaviero_remote/src/transport/connection.dart';
import 'package:gaviero_remote/src/transport/socket.dart';
import 'package:gaviero_remote/src/ui/composer.dart';

final class CapturingSocket implements WsSocket {
  final _controller = StreamController<dynamic>();
  final sent = <Map<String, Object?>>[];

  @override
  int? closeCode;
  @override
  String? closeReason;

  @override
  Stream<dynamic> get frames => _controller.stream;

  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, Object?>);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_controller.isClosed) await _controller.close();
  }

  void serverSend(Map<String, Object?> envelope) =>
      _controller.add(jsonEncode(envelope));
}

int _seq = 1;

Future<(RemoteController, CapturingSocket)> connectedController({
  List<String> capabilities = const [],
}) async {
  _seq = 1;
  final socket = CapturingSocket();
  final controller = RemoteController(
    connection: RemoteConnection(connector: (url, token) async => socket),
    state: AppState(),
  );
  await controller.connection.start(Uri.parse('wss://h/v1/ws'), 't');
  socket.serverSend({
    'version': {'major': 1, 'minor': 0},
    'instance_id': 'i1',
    'seq': _seq++,
    'revision': 1,
    'type': 'hello',
    'payload': {
      'protocol_version': {'major': 1, 'minor': 0},
      'instance_id': 'i1',
      'tui_version': '0.1.0',
      'workspace': {'id': 'w', 'display_name': 'w'},
      'capabilities': capabilities,
      'confirm_required': ['/reset', '/autoapprove'],
      // Deliberately NOT the full desktop set: /run and /compact are absent.
      'allowed_slash_commands': ['/model', '/reset', '/lite'],
      'limits': {
        'max_frame_bytes': 262144,
        'max_prompt_bytes': 131072,
        'command_rate_per_second': 10,
      },
    },
  });
  socket.serverSend({
    'version': {'major': 1, 'minor': 0},
    'instance_id': 'i1',
    'seq': _seq++,
    'revision': 1,
    'type': 'conversation_state_changed',
    'payload': {
      'conversation': {
        'conv_id': 'c1',
        'conv_revision': 1,
        'title': 'Chat',
        'is_streaming': false,
        'auto_approve': false,
      },
      'active_id': 'c1',
    },
  });
  await Future<void>.delayed(Duration.zero);
  return (controller, socket);
}

Widget host(RemoteController controller) => MaterialApp(
      home: Scaffold(body: Composer(controller: controller)),
    );

void main() {
  testWidgets('chips come only from the server allow-list', (tester) async {
    final (controller, _) = (await tester.runAsync(connectedController))!;
    await tester.pumpWidget(host(controller));
    expect(find.widgetWithText(ActionChip, '/model'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '/reset'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '/lite'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '/run'), findsNothing);
    expect(find.widgetWithText(ActionChip, '/compact'), findsNothing);
  });

  testWidgets('a confirm-gated chip raises a dialog and sends '
      'confirmed: true', (tester) async {
    final (controller, socket) = (await tester.runAsync(connectedController))!;
    await tester.pumpWidget(host(controller));

    await tester.tap(find.widgetWithText(ActionChip, '/reset'));
    await tester.pumpAndSettle();
    expect(find.text('Send /reset?'), findsOneWidget);
    expect(socket.sent.where((f) => f['type'] == 'slash'), isEmpty,
        reason: 'nothing is sent before the dialog is answered');

    await tester.tap(find.widgetWithText(FilledButton, 'Send /reset'));
    await tester.pumpAndSettle();
    final frame = socket.sent.lastWhere((f) => f['type'] == 'slash');
    final payload = frame['payload'] as Map<String, Object?>;
    expect(payload['line'], '/reset');
    expect(payload['confirmed'], isTrue);
  });

  testWidgets('cancelling the confirm dialog sends nothing', (tester) async {
    final (controller, socket) = (await tester.runAsync(connectedController))!;
    await tester.pumpWidget(host(controller));
    await tester.tap(find.widgetWithText(ActionChip, '/reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(socket.sent.where((f) => f['type'] == 'slash'), isEmpty);
  });

  testWidgets('an argument-taking chip prefills the composer', (tester) async {
    final (controller, socket) = (await tester.runAsync(connectedController))!;
    await tester.pumpWidget(host(controller));
    await tester.tap(find.widgetWithText(ActionChip, '/model'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '/model '), findsOneWidget);
    expect(socket.sent.where((f) => f['type'] == 'slash'), isEmpty);
  });

  testWidgets('slash_not_allowed renders as a calm inline notice',
      (tester) async {
    final (controller, socket) = (await tester.runAsync(connectedController))!;
    await tester.pumpWidget(host(controller));

    await tester.enterText(find.byType(TextField), '/run build.gaviero');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    final frame = socket.sent.lastWhere((f) => f['type'] == 'slash');
    final commandId = frame['command_id'] as String;
    await tester.runAsync(() async {
      socket.serverSend({
        'version': {'major': 1, 'minor': 0},
        'instance_id': 'i1',
        'seq': _seq++,
        'revision': 1,
        'type': 'command_error',
        'payload': {
          'command_id': commandId,
          'code': 'slash_not_allowed',
          'message': 'denied remotely',
        },
      });
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.textContaining("isn't available from the phone"),
        findsOneWidget);
    expect(find.byType(SnackBar), findsNothing,
        reason: 'policy, not a failure — no scary error surface');
  });

  testWidgets('plain text goes out as send_prompt', (tester) async {
    final (controller, socket) = (await tester.runAsync(connectedController))!;
    await tester.pumpWidget(host(controller));
    await tester.enterText(find.byType(TextField), 'hello agent');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    final frame = socket.sent.lastWhere((f) => f['type'] == 'send_prompt');
    expect((frame['payload'] as Map)['text'], 'hello agent');
    expect((frame['payload'] as Map)['conv_id'], 'c1');
  });

  group('@ file completion', () {
    test('fileReferenceAt follows the desktop token rule', () {
      expect(fileReferenceAt('read @src/ma', 12), (start: 5, query: 'src/ma'));
      expect(fileReferenceAt('@', 1), (start: 0, query: ''));
      expect(fileReferenceAt('see @src/main.rs now', 8),
          (start: 4, query: 'src'));
      expect(fileReferenceAt('line\n@lib', 9), (start: 5, query: 'lib'));
      expect(fileReferenceAt('mail me@host', 12), isNull);
      expect(fileReferenceAt('@src/main.rs done', 17), isNull);
      expect(fileReferenceAt('no reference', 12), isNull);
      expect(fileReferenceAt('/model @x', 9), isNull);
    });

    Future<void> reply(WidgetTester tester, CapturingSocket socket,
        Map<String, Object?> request, List<String> files) async {
      await tester.runAsync(() async {
        socket.serverSend({
          'version': {'major': 1, 'minor': 1},
          'instance_id': 'i1',
          'seq': _seq++,
          'revision': 1,
          'type': 'command_result',
          'payload': {
            'command_id': request['command_id'],
            'status': 'completed',
            'result': {
              'query': (request['payload'] as Map)['query'],
              'files': files,
            },
          },
        });
        await Future<void>.delayed(Duration.zero);
      });
      // The reply's continuation runs in the microtask flush that ends the
      // first pump; the frame its setState schedules is drawn by the second.
      await tester.pump();
      await tester.pump();
    }

    List<Map<String, Object?>> completionRequests(CapturingSocket socket) =>
        socket.sent
            .where((f) => f['type'] == 'request_file_completions')
            .toList();

    testWidgets('suggestions replace the chips and a tap inserts the path',
        (tester) async {
      final (controller, socket) = (await tester.runAsync(
        () => connectedController(capabilities: ['file_completions']),
      ))!;
      await tester.pumpWidget(host(controller));

      await tester.enterText(find.byType(TextField), 'please read @src/ma');
      await tester.pump(const Duration(milliseconds: 200));
      final request = completionRequests(socket).single;
      expect(request['payload'], {'query': 'src/ma'});

      await reply(tester, socket, request, ['src/main.rs', 'src/model.rs']);
      expect(find.byKey(const Key('file-suggestions')), findsOneWidget);
      expect(find.text('main.rs'), findsOneWidget);
      expect(find.text('model.rs'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, '/model'), findsNothing);

      await tester.tap(find.text('main.rs'));
      await tester.pump();
      expect(find.widgetWithText(TextField, 'please read @src/main.rs '),
          findsOneWidget);
      expect(find.byKey(const Key('file-suggestions')), findsNothing);
      expect(find.widgetWithText(ActionChip, '/model'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(completionRequests(socket), hasLength(1),
          reason: 'accepting closes the token; nothing more to complete');
    });

    testWidgets('a reply for a query typed past is dropped and the current '
        'query fetched', (tester) async {
      final (controller, socket) = (await tester.runAsync(
        () => connectedController(capabilities: ['file_completions']),
      ))!;
      await tester.pumpWidget(host(controller));

      await tester.enterText(find.byType(TextField), '@sr');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField), '@src/li');
      await tester.pump(const Duration(milliseconds: 200));
      expect(completionRequests(socket), hasLength(1),
          reason: 'one request in flight at a time');

      await reply(tester, socket, completionRequests(socket).first,
          ['stale.rs']);
      expect(find.text('stale.rs'), findsNothing);
      final second = completionRequests(socket);
      expect(second, hasLength(2));
      expect(second.last['payload'], {'query': 'src/li'});

      await reply(tester, socket, second.last, ['src/lib.rs']);
      expect(find.text('lib.rs'), findsOneWidget);
    });

    testWidgets('a failed request clears the previous matches',
        (tester) async {
      final (controller, socket) = (await tester.runAsync(
        () => connectedController(capabilities: ['file_completions']),
      ))!;
      await tester.pumpWidget(host(controller));

      await tester.enterText(find.byType(TextField), '@src');
      await tester.pump(const Duration(milliseconds: 200));
      await reply(tester, socket, completionRequests(socket).single,
          ['src/main.rs']);
      expect(find.text('main.rs'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '@src/x');
      await tester.pump(const Duration(milliseconds: 200));
      final failed = completionRequests(socket).last;
      await tester.runAsync(() async {
        socket.serverSend({
          'version': {'major': 1, 'minor': 1},
          'instance_id': 'i1',
          'seq': _seq++,
          'revision': 1,
          'type': 'command_error',
          'payload': {
            'command_id': failed['command_id'],
            'code': 'rate_limited',
            'message': 'slow down',
          },
        });
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('file-suggestions')), findsNothing);
    });

    testWidgets('a server without file_completions gets no requests',
        (tester) async {
      final (controller, socket) = (await tester.runAsync(connectedController))!;
      await tester.pumpWidget(host(controller));
      await tester.enterText(find.byType(TextField), 'read @src');
      await tester.pump(const Duration(seconds: 1));
      expect(completionRequests(socket), isEmpty);
      expect(find.byKey(const Key('file-suggestions')), findsNothing);
    });
  });
}
