/// Connection lifecycle (PLAN.md B3): bearer-header auth, `client_hello`
/// first, envelope bookkeeping, seq-gap detection, instance-change
/// resnapshot, exponential-backoff reconnect, and the §3.7 close-code table.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../protocol/protocol.dart';
import 'socket.dart';

const clientName = 'gaviero-remote-android';
const clientAppVersion = '0.1.0';

enum ConnectionPhase {
  /// Paired but not started, or stopped after a client-bug close.
  disconnected,
  connecting,

  /// Upgrade done, `client_hello` sent, awaiting `hello`.
  handshaking,
  connected,

  /// The TUI is not reachable (network drop or 4007). Backing off, polling
  /// gently. This is routine, not an error.
  offline,

  /// 4005 — another device connected. Distinct from a network error.
  evicted,

  /// 4002 or a `hello` protocol-major mismatch. Non-fatal; no retry loop.
  versionMismatch,

  /// 4001 / 4006 — the stored token is dead. Route to pairing.
  unauthorized,
}

/// Application close codes (PROTOCOL.md §Close codes).
abstract final class CloseCodes {
  static const unauthorized = 4001;
  static const unsupportedVersion = 4002;
  static const protocolError = 4003;
  static const frameTooLarge = 4004;
  static const replaced = 4005;
  static const tokenRotated = 4006;
  static const serverShutdown = 4007;
  static const slowClient = 4008;
}

sealed class CommandOutcome {
  const CommandOutcome();
}

final class CommandOk extends CommandOutcome {
  final CommandResult result;
  const CommandOk(this.result);
}

final class CommandFail extends CommandOutcome {
  final CommandError error;
  const CommandFail(this.error);
}

/// The socket died before a terminal response arrived. Retrying is safe:
/// the server deduplicates `command_id`s.
final class CommandDropped extends CommandOutcome {
  const CommandDropped();
}

final class RemoteConnection extends ChangeNotifier {
  final WsConnector _connector;
  final Random _random;

  /// Delivered every decoded server envelope after connection bookkeeping.
  void Function(ServerEnvelope envelope)? onEnvelope;

  /// The TUI restarted (`instance_id` changed): drop local state; a fresh
  /// snapshot is already on its way.
  VoidCallback? onInstanceChanged;

  /// 4001 / 4006: the stored token must be cleared.
  Future<void> Function()? onTokenInvalid;

  ConnectionPhase _phase = ConnectionPhase.disconnected;
  String? _statusDetail;
  Uri? _url;
  String? _token;
  WsSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _helloTimeout;
  bool _stopped = true;

  Hello? _hello;
  String? _instanceId;
  int? _lastSeq;
  bool _snapshotInFlight = false;

  /// One free reconnect after a 4003/4004 (client bug); a second one without
  /// an intervening successful hello stops the loop.
  bool _protocolErrorRetryUsed = false;

  /// Set before a client-initiated close whose phase is already decided
  /// (version mismatch): the onDone handler must not reclassify it as a
  /// network drop.
  bool _closeHandled = false;

  int _attempts = 0;
  int _commandCounter = 0;
  late final String _sessionNonce =
      _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  final Map<String, Completer<CommandOutcome>> _pending = {};

  RemoteConnection({WsConnector? connector, Random? random})
      : _connector = connector ?? IoWsSocket.connect,
        _random = random ?? Random();

  ConnectionPhase get phase => _phase;

  /// Human-readable detail for the current phase (close reason etc.).
  String? get statusDetail => _statusDetail;
  Hello? get hello => _hello;
  String? get instanceId => _instanceId;
  bool get isConnected => _phase == ConnectionPhase.connected;

  /// Exposed for tests.
  int get reconnectAttempts => _attempts;

  static Duration backoffDelay(int attempts, Random random) {
    final base = min(30000, 1000 * (1 << min(attempts, 5)));
    return Duration(milliseconds: base + random.nextInt(500));
  }

  Future<void> start(Uri url, String token) async {
    _url = url;
    _token = token;
    _stopped = false;
    _attempts = 0;
    await _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _helloTimeout?.cancel();
    await _teardownSocket();
    _setPhase(ConnectionPhase.disconnected);
  }

  /// Reconnect immediately (app resumed from background). A dead socket is
  /// routine here — the server closes after 60 s without traffic.
  Future<void> resume() async {
    if (_stopped || _url == null) return;
    if (_phase == ConnectionPhase.connected ||
        _phase == ConnectionPhase.connecting ||
        _phase == ConnectionPhase.handshaking) {
      return;
    }
    _reconnectTimer?.cancel();
    await _connect();
  }

  String _nextCommandId() => 'cmd-$_sessionNonce-${++_commandCounter}';

  /// Sends a command and resolves on its single terminal response.
  Future<CommandOutcome> send(ClientPayload payload) {
    final socket = _socket;
    if (socket == null || _phase != ConnectionPhase.connected) {
      return Future.value(const CommandDropped());
    }
    final commandId = _nextCommandId();
    final completer = Completer<CommandOutcome>();
    _pending[commandId] = completer;
    socket.send(ClientEnvelope(
      instanceId: _instanceId,
      commandId: commandId,
      payload: payload,
    ).encode());
    return completer.future;
  }

  Future<void> _connect() async {
    final url = _url;
    final token = _token;
    if (url == null || token == null || _stopped) return;
    _setPhase(ConnectionPhase.connecting);
    final WsSocket socket;
    try {
      socket = await _connector(url, token);
    } catch (e) {
      _statusDetail = 'Instance offline';
      _setPhase(ConnectionPhase.offline);
      _scheduleReconnect();
      return;
    }
    if (_stopped) {
      await socket.close();
      return;
    }
    _socket = socket;
    _setPhase(ConnectionPhase.handshaking);
    // First frame after upgrade, and the only one with a null instance_id.
    socket.send(ClientEnvelope(
      instanceId: null,
      commandId: _nextCommandId(),
      payload: const ClientHello(
        protocolVersion: protocolVersion,
        clientName: clientName,
        clientVersion: clientAppVersion,
      ),
    ).encode());
    _helloTimeout = Timer(const Duration(seconds: 10), () {
      _socket?.close(1000, 'hello timeout');
    });
    _subscription = socket.frames.listen(
      _onFrame,
      onDone: _onClosed,
      onError: (Object _) => _onClosed(),
    );
  }

  void _onFrame(dynamic raw) {
    if (raw is! String) return; // Binary frames are a server-side error.
    final ServerEnvelope envelope;
    try {
      envelope = ServerEnvelope.decode(raw);
    } on Object catch (e) {
      debugPrint('gaviero-remote: undecodable frame dropped: $e');
      return;
    }

    if (envelope.payload case final Hello hello) {
      _helloTimeout?.cancel();
      if (!hello.serverProtocolVersion.isCompatibleWith(protocolVersion)) {
        _statusDetail =
            'App speaks v${protocolVersion.major}, desktop speaks '
            'v${hello.serverProtocolVersion.major}';
        _setPhase(ConnectionPhase.versionMismatch);
        _closeHandled = true;
        _socket?.close(1000, 'version mismatch');
        return;
      }
      final previousInstance = _instanceId;
      _hello = hello;
      _instanceId = hello.instanceId;
      _lastSeq = envelope.seq;
      _attempts = 0;
      _protocolErrorRetryUsed = false;
      _setPhase(ConnectionPhase.connected);
      if (previousInstance != null && previousInstance != hello.instanceId) {
        onInstanceChanged?.call();
      }
      onEnvelope?.call(envelope);
      return;
    }

    // TUI restart mid-stream: drop state; the server will be sending a fresh
    // snapshot for the new instance.
    if (_instanceId != null && envelope.instanceId != _instanceId) {
      _instanceId = envelope.instanceId;
      _lastSeq = envelope.seq;
      onInstanceChanged?.call();
      _requestSnapshot();
    } else {
      final last = _lastSeq;
      if (last != null && envelope.seq > last + 1) {
        _requestSnapshot();
      }
      if (_lastSeq == null || envelope.seq > _lastSeq!) {
        _lastSeq = envelope.seq;
      }
    }

    switch (envelope.payload) {
      case Snapshot():
        _snapshotInFlight = false;
      case CommandResult(:final commandId) when _pending.containsKey(commandId):
        _pending.remove(commandId)!
            .complete(CommandOk(envelope.payload as CommandResult));
      case CommandError(:final commandId) when _pending.containsKey(commandId):
        _pending.remove(commandId)!
            .complete(CommandFail(envelope.payload as CommandError));
      case UnknownServerPayload(:final type):
        debugPrint('gaviero-remote: ignoring unknown frame type "$type"');
      default:
        break;
    }
    onEnvelope?.call(envelope);
  }

  void _requestSnapshot() {
    if (_snapshotInFlight) return;
    _snapshotInFlight = true;
    _socket?.send(ClientEnvelope(
      instanceId: _instanceId,
      commandId: _nextCommandId(),
      payload: const RequestSnapshot(),
    ).encode());
  }

  void _onClosed() {
    final code = _socket?.closeCode;
    final reason = _socket?.closeReason;
    _failPending();
    _teardownSocketSync();
    if (_stopped) return;
    if (_closeHandled) {
      _closeHandled = false;
      return;
    }

    switch (code) {
      case CloseCodes.unauthorized:
        _statusDetail = 'Pairing is no longer valid — scan the QR again.';
        _setPhase(ConnectionPhase.unauthorized);
        onTokenInvalid?.call();
      case CloseCodes.tokenRotated:
        _statusDetail = 'Pairing was reset on the desktop.';
        _setPhase(ConnectionPhase.unauthorized);
        onTokenInvalid?.call();
      case CloseCodes.unsupportedVersion:
        _statusDetail = "App and desktop versions don't match.";
        _setPhase(ConnectionPhase.versionMismatch);
      case CloseCodes.replaced:
        _statusDetail = 'Connected on another device.';
        _setPhase(ConnectionPhase.evicted);
      case CloseCodes.protocolError || CloseCodes.frameTooLarge:
        debugPrint('gaviero-remote: server close $code: $reason');
        if (_protocolErrorRetryUsed) {
          _statusDetail = 'Protocol error (close $code): $reason';
          _setPhase(ConnectionPhase.disconnected);
        } else {
          _protocolErrorRetryUsed = true;
          _setPhase(ConnectionPhase.offline);
          _scheduleReconnect();
        }
      case CloseCodes.serverShutdown:
        _statusDetail = 'Instance offline';
        _setPhase(ConnectionPhase.offline);
        _scheduleReconnect(gentle: true);
      case CloseCodes.slowClient:
        _setPhase(ConnectionPhase.offline);
        _scheduleReconnect();
      default:
        // Routine network drop (backgrounding, Wi-Fi loss, ping timeout).
        _statusDetail = 'Instance offline';
        _setPhase(ConnectionPhase.offline);
        _scheduleReconnect();
    }
  }

  void _scheduleReconnect({bool gentle = false}) {
    if (_stopped) return;
    if (gentle && _attempts < 3) _attempts = 3;
    final delay = backoffDelay(_attempts, _random);
    _attempts++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _connect);
  }

  void _failPending() {
    for (final completer in _pending.values) {
      completer.complete(const CommandDropped());
    }
    _pending.clear();
  }

  Future<void> _teardownSocket() async {
    _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
  }

  void _teardownSocketSync() {
    _subscription?.cancel();
    _subscription = null;
    _socket = null;
  }

  void _setPhase(ConnectionPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _helloTimeout?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
