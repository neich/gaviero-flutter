/// B3 verification (machine-verifiable part): handshake order, envelope
/// bookkeeping, seq-gap resnapshot, instance-change handling, close-code
/// classification, backoff, and command correlation — against a fake socket.
/// Real-device checks (Wi-Fi kill, second-device eviction, proxy header
/// inspection) are listed in plan_log.md as pending user verification.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/protocol.dart';
import 'package:gaviero_remote/src/transport/connection.dart';
import 'package:gaviero_remote/src/transport/socket.dart';

final class FakeSocket implements WsSocket {
  final _controller = StreamController<dynamic>();
  final sent = <Map<String, Object?>>[];

  @override
  int? closeCode;

  @override
  String? closeReason;

  bool clientClosed = false;

  @override
  Stream<dynamic> get frames => _controller.stream;

  @override
  void send(String text) {
    sent.add(jsonDecode(text) as Map<String, Object?>);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    clientClosed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  void serverSend(Map<String, Object?> envelope) =>
      _controller.add(jsonEncode(envelope));

  Future<void> serverClose(int? code, [String? reason]) async {
    closeCode = code;
    closeReason = reason;
    await _controller.close();
  }
}

Map<String, Object?> serverEnvelope(
  String type,
  Map<String, Object?> payload, {
  required int seq,
  String instanceId = 'inst-1',
  int revision = 1,
}) =>
    {
      'version': {'major': 1, 'minor': 0},
      'instance_id': instanceId,
      'seq': seq,
      'revision': revision,
      'type': type,
      'payload': payload,
    };

Map<String, Object?> helloPayload({String instanceId = 'inst-1', int major = 1}) => {
      'protocol_version': {'major': major, 'minor': 0},
      'instance_id': instanceId,
      'tui_version': '0.1.0',
      'workspace': {'id': 'abc123', 'display_name': 'gaviero'},
      'capabilities': <String>[],
      'confirm_required': ['/reset'],
      'allowed_slash_commands': ['/model', '/reset'],
      'limits': {
        'max_frame_bytes': 262144,
        'max_prompt_bytes': 131072,
        'command_rate_per_second': 10,
      },
    };

final class Harness {
  final sockets = <FakeSocket>[];
  int connectCalls = 0;
  late final RemoteConnection connection;

  Harness() {
    connection = RemoteConnection(
      connector: (url, token) {
        connectCalls++;
        final socket = FakeSocket();
        sockets.add(socket);
        return Future.value(socket);
      },
      random: Random(42),
    );
  }

  FakeSocket get socket => sockets.last;

  Future<void> start() =>
      connection.start(Uri.parse('wss://host:4443/v1/ws'), 'tok');

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> handshake() async {
    await start();
    socket.serverSend(serverEnvelope('hello', helloPayload(), seq: 1));
    await settle();
  }
}

void main() {
  test('client_hello is the first frame and carries a literal null '
      'instance_id', () async {
    final h = Harness();
    await h.start();
    expect(h.socket.sent, hasLength(1));
    final frame = h.socket.sent.single;
    expect(frame['type'], 'client_hello');
    expect(frame.containsKey('instance_id'), isTrue);
    expect(frame['instance_id'], isNull);
    expect(frame['version'], {'major': 1, 'minor': 2});
    expect(h.connection.phase, ConnectionPhase.handshaking);
  });

  test('hello completes the handshake; later frames echo instance_id',
      () async {
    final h = Harness();
    await h.handshake();
    expect(h.connection.phase, ConnectionPhase.connected);
    expect(h.connection.hello!.allowedSlashCommands, contains('/model'));
    unawaited(h.connection.send(const SendPrompt(convId: 'c1', text: 'hi')));
    await h.settle();
    expect(h.socket.sent.last['instance_id'], 'inst-1');
    expect(h.socket.sent.last['type'], 'send_prompt');
  });

  test('a seq gap triggers exactly one request_snapshot', () async {
    final h = Harness();
    await h.handshake();
    h.socket.serverSend(serverEnvelope(
        'streaming_status',
        {'conv_id': 'c1', 'turn_id': 't1', 'status': 'thinking'},
        seq: 2));
    // seq jumps 2 -> 5: missed frames.
    h.socket.serverSend(serverEnvelope(
        'streaming_status',
        {'conv_id': 'c1', 'turn_id': 't1', 'status': 'still thinking'},
        seq: 5));
    h.socket.serverSend(serverEnvelope(
        'streaming_status',
        {'conv_id': 'c1', 'turn_id': 't1', 'status': 'more'},
        seq: 9));
    await h.settle();
    final snapshots =
        h.socket.sent.where((f) => f['type'] == 'request_snapshot');
    expect(snapshots, hasLength(1),
        reason: 'gap resnapshot must not be re-sent while one is in flight');
  });

  test('an instance_id change drops state and resnapshots', () async {
    final h = Harness();
    await h.handshake();
    var dropped = 0;
    h.connection.onInstanceChanged = () => dropped++;
    h.socket.serverSend(serverEnvelope(
        'streaming_status',
        {'conv_id': 'c1', 'turn_id': 't1', 'status': 'thinking'},
        seq: 1,
        instanceId: 'inst-2'));
    await h.settle();
    expect(dropped, 1);
    expect(h.socket.sent.last['type'], 'request_snapshot');
  });

  test('a hello protocol-major mismatch is non-fatal and does not retry',
      () async {
    final h = Harness();
    await h.start();
    h.socket.serverSend(
        serverEnvelope('hello', helloPayload(major: 2), seq: 1));
    await h.settle();
    expect(h.connection.phase, ConnectionPhase.versionMismatch);
    expect(h.socket.clientClosed, isTrue);
    expect(h.connection.statusDetail, contains('v2'));
  });

  test('4005 replaced: distinct eviction, no reconnect', () async {
    final h = Harness();
    await h.handshake();
    await h.socket.serverClose(4005, 'replaced');
    await h.settle();
    expect(h.connection.phase, ConnectionPhase.evicted);
    expect(h.connection.statusDetail, 'Connected on another device.');
    expect(h.connectCalls, 1);
  });

  test('4001 and 4006 clear the token and route to pairing', () async {
    for (final code in [4001, 4006]) {
      final h = Harness();
      await h.handshake();
      var cleared = 0;
      h.connection.onTokenInvalid = () async => cleared++;
      await h.socket.serverClose(code);
      await h.settle();
      expect(h.connection.phase, ConnectionPhase.unauthorized,
          reason: 'close $code');
      expect(cleared, 1, reason: 'close $code');
    }
  });

  test('4002 unsupported_version: no retry loop', () async {
    final h = Harness();
    await h.handshake();
    await h.socket.serverClose(4002);
    await h.settle();
    expect(h.connection.phase, ConnectionPhase.versionMismatch);
    expect(h.connectCalls, 1);
  });

  test('a network drop reconnects with backoff and resyncs', () {
    fakeAsync((async) {
      final h = Harness();
      h.start();
      async.flushMicrotasks();
      h.socket.serverSend(serverEnvelope('hello', helloPayload(), seq: 1));
      async.flushMicrotasks();
      expect(h.connection.phase, ConnectionPhase.connected);

      h.socket.serverClose(null); // abnormal close, e.g. Wi-Fi died
      async.flushMicrotasks();
      expect(h.connection.phase, ConnectionPhase.offline);

      async.elapse(const Duration(seconds: 2));
      expect(h.connectCalls, 2, reason: 'backoff timer must reconnect');
      h.socket.serverSend(serverEnvelope('hello', helloPayload(), seq: 7));
      async.flushMicrotasks();
      expect(h.connection.phase, ConnectionPhase.connected);
      expect(h.connection.reconnectAttempts, 0,
          reason: 'successful hello resets backoff');
    });
  });

  test('4003 protocol_error reconnects once, then stops', () {
    fakeAsync((async) {
      final h = Harness();
      h.start();
      async.flushMicrotasks();
      h.socket.serverSend(serverEnvelope('hello', helloPayload(), seq: 1));
      async.flushMicrotasks();

      h.socket.serverClose(4003, 'bad frame');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      expect(h.connectCalls, 2);
      h.socket.serverSend(serverEnvelope('hello', helloPayload(), seq: 5));
      async.flushMicrotasks();

      // A second 4003 without an intervening success... the retry budget was
      // reset by the successful hello, so one more retry happens, then stop.
      h.socket.serverClose(4003, 'bad frame again');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      expect(h.connectCalls, 3);
      h.socket.serverClose(4003, 'still bad');
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));
      expect(h.connectCalls, 3, reason: 'no infinite 4003 loop');
      expect(h.connection.phase, ConnectionPhase.disconnected);
    });
  });

  test('commands resolve on their single terminal response', () async {
    final h = Harness();
    await h.handshake();
    final future = h.connection.send(const SendPrompt(convId: 'c1', text: 'x'));
    await h.settle();
    final commandId = h.socket.sent.last['command_id'] as String;
    h.socket.serverSend(serverEnvelope(
        'command_result',
        {
          'command_id': commandId,
          'status': 'accepted',
          'result': {'turn_id': 't9'}
        },
        seq: 2));
    final outcome = await future;
    expect(outcome, isA<CommandOk>());
    expect((outcome as CommandOk).result.status, CommandStatus.accepted);
  });

  test('command_error resolves the same command future', () async {
    final h = Harness();
    await h.handshake();
    final future = h.connection.send(const Slash(
        convId: 'c1', line: '/run x', confirmed: false));
    await h.settle();
    final commandId = h.socket.sent.last['command_id'] as String;
    h.socket.serverSend(serverEnvelope(
        'command_error',
        {
          'command_id': commandId,
          'code': 'slash_not_allowed',
          'message': 'denied remotely'
        },
        seq: 2));
    final outcome = await future;
    expect(outcome, isA<CommandFail>());
    expect((outcome as CommandFail).error.code, ErrorCode.slashNotAllowed);
  });

  test('in-flight commands resolve as dropped when the socket dies',
      () async {
    final h = Harness();
    await h.handshake();
    final future = h.connection.send(const SendPrompt(convId: 'c1', text: 'x'));
    await h.socket.serverClose(null);
    expect(await future, isA<CommandDropped>());
  });

  test('backoff grows exponentially and caps at 30s', () {
    final random = Random(1);
    Duration at(int attempts) =>
        RemoteConnection.backoffDelay(attempts, random);
    expect(at(0).inMilliseconds, inInclusiveRange(1000, 1500));
    expect(at(1).inMilliseconds, inInclusiveRange(2000, 2500));
    expect(at(3).inMilliseconds, inInclusiveRange(8000, 8500));
    expect(at(10).inMilliseconds, inInclusiveRange(30000, 30500));
  });
}
