/// The app above the instances: stored machines and instances, the machine
/// directory, pairing, and one [RemoteController] session per recently used
/// instance. Switching instances keeps the previous session (its
/// conversations, and the screens built on it) and only closes its socket:
/// one instance holds a connection at a time. Coming back reconnects, and the
/// server's snapshot brings the kept state up to date.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/protocol.dart';
import '../services/directory_client.dart';
import '../services/instance_store.dart';
import '../services/relay_alerts.dart';
import '../services/secure_store.dart';
import '../transport/connection.dart';
import 'controller.dart';

final class RemoteHub extends ChangeNotifier {
  /// Sessions kept in memory, the visible one included; the least recently
  /// shown beyond this is closed.
  static const maxSessions = 4;

  final InstanceStore instanceStore;
  final DirectoryClient directoryClient;
  final RelayAlerts relayAlerts;
  final RemoteConnection Function() _newConnection;

  /// Notification hooks, wired into every session's state.
  void Function(PermissionRequest request)? onPermissionRequested;
  void Function(StreamingEnded ended)? onStreamingEnded;

  /// Creation order — the order of the screens built on them, so switching
  /// never reorders (and never rebuilds) a kept screen.
  final List<RemoteController> _sessions = [];
  final Map<RemoteController, int> _lastShown = {};
  int _clock = 0;
  RemoteController? _session;
  bool _showingInstances = false;
  String? _needsPairingHost;

  RemoteHub({
    InstanceStore? instanceStore,
    DirectoryClient? directoryClient,
    RelayAlerts? relayAlerts,
    RemoteConnection Function()? connectionFactory,
  }) : instanceStore = instanceStore ?? InstanceStore(),
       directoryClient = directoryClient ?? DirectoryClient(),
       relayAlerts = relayAlerts ?? RelayAlerts(),
       _newConnection = connectionFactory ?? RemoteConnection.new;

  /// The visible instance's session, also while the picker covers it.
  RemoteController? get session => _session;
  InstanceRecord? get current => _session?.current;
  List<RemoteController> get sessions => List.unmodifiable(_sessions);

  /// The instance picker covers the current session (which stays connected
  /// until another instance is chosen).
  bool get showingInstances => _showingInstances || _session == null;
  String? get needsPairingHost => _needsPairingHost;
  bool get isPaired => instanceStore.doc.machines.isNotEmpty;

  void showInstances() {
    if (_showingInstances) return;
    _showingInstances = true;
    notifyListeners();
  }

  /// Back from the picker to the current session.
  void hideInstances() {
    if (!_showingInstances) return;
    _showingInstances = false;
    notifyListeners();
  }

  /// Loads stored instances, refreshes the machine directory so online
  /// status and URLs are current, then reconnects to
  /// [StoreDocument.lastInstance] when present.
  Future<bool> initialize() async {
    await instanceStore.load();
    unawaited(relayAlerts.sync(instanceStore.doc));
    // Doze holds the relay stream until the app is opened unless this
    // exemption was granted. Pairing asks too; a dismissed dialog is asked
    // again on the next cold start, and the activity no-ops once granted.
    if (instanceStore.doc.machines.any(
      (m) => m.relayHost != null && m.relaySecret != null && !m.needsPairing,
    )) {
      unawaited(relayAlerts.requestBatteryExemption());
    }
    notifyListeners();
    await refreshDirectory();
    final last = instanceStore.doc.lastInstance;
    if (last == null) return false;
    final inst = instanceStore.instance(last);
    if (inst == null) return false;
    await connect(inst);
    return true;
  }

  Future<void> pair(PairingConfig config) async {
    final host = config.machineHost;
    await instanceStore.upsertMachine(
      MachineRecord(
        host: host,
        token: config.token,
        directoryUrl: config.directoryUrl,
        pairedAt: DateTime.now().toUtc().toIso8601String(),
        needsPairing: false,
        tlsCa: config.tlsCa,
        relayHost: config.relayHost,
        relaySecret: config.relaySecret,
      ),
    );
    final inst = InstanceRecord(
      machineHost: host,
      workspaceId: config.workspaceId,
      displayName: config.workspace.isEmpty ? host : config.workspace,
      url: config.url,
    );
    await instanceStore.upsertInstance(inst);
    // The relay alert service stays reliable under OEM battery managers only
    // with the exemption (asked once per pairing).
    unawaited(relayAlerts.sync(instanceStore.doc));
    unawaited(relayAlerts.requestBatteryExemption());
    _needsPairingHost = null;
    notifyListeners();
    await connect(instanceStore.instance(inst.key) ?? inst);
  }

  /// Replace the token of a machine paired by QR earlier — manual entry
  /// cannot carry the CA or the relay fields, so it can't pair a new one.
  /// Directory refresh then fills in running instances.
  Future<void> pairMachineOnly(String host, String token) async {
    final existing = instanceStore.machine(host);
    if (existing == null) {
      throw const PairingError(
          'Scan the QR code from /remote first. Manual entry only replaces '
          'the token of a machine that is already paired.');
    }
    await instanceStore.upsertMachine(
      existing.copyWith(
        token: token,
        pairedAt: DateTime.now().toUtc().toIso8601String(),
        needsPairing: false,
      ),
    );
    _needsPairingHost = null;
    notifyListeners();
    await refreshDirectory();
  }

  /// Show [inst], reusing its kept session. The session left behind keeps
  /// its state but closes its socket.
  Future<void> connect(InstanceRecord inst) async {
    var session = _sessionFor(inst);
    final previous = _session;
    if (previous != null && previous != session) {
      await previous.connection.stop();
    }
    final moved = session != null && session.current?.url != inst.url;
    if (session == null) {
      session = _open(inst);
    } else {
      session.updateInstance(inst);
    }
    _session = session;
    _lastShown[session] = ++_clock;
    _showingInstances = false;
    _needsPairingHost = null;
    await _evictBeyondCap();
    await instanceStore.setLastInstance(inst.key);
    notifyListeners();
    final machine = instanceStore.machine(inst.machineHost);
    if (machine == null || machine.needsPairing) return;
    final connection = session.connection;
    if (!moved &&
        (connection.isConnected ||
            connection.phase == ConnectionPhase.connecting ||
            connection.phase == ConnectionPhase.handshaking)) {
      return;
    }
    await connection.start(
      Uri.parse(inst.url),
      machine.token,
      tlsCa: machine.tlsCa,
      relayHost: machine.relayHost,
    );
  }

  /// Close the visible session entirely; the picker is shown.
  Future<void> disconnect() async {
    final session = _session;
    if (session != null) await _close(session);
    notifyListeners();
  }

  Future<void> refreshDirectory() async {
    await directoryClient.refresh(instanceStore);
    notifyListeners();
  }

  Future<void> forgetInstance(InstanceKey key) async {
    for (final s in [..._sessions]) {
      if (s.current?.key == key) await _close(s);
    }
    await instanceStore.forgetInstance(key);
    notifyListeners();
  }

  Future<void> forgetMachine(String host) async {
    for (final s in [..._sessions]) {
      if (s.current?.machineHost == host) await _close(s);
    }
    await instanceStore.forgetMachine(host);
    unawaited(relayAlerts.sync(instanceStore.doc));
    if (_needsPairingHost == host) _needsPairingHost = null;
    notifyListeners();
  }

  /// App resumed from background: a dead socket is routine (the server culls
  /// after 60 s without traffic). Refresh the directory first so an instance
  /// whose URL changed while we were away is followed; otherwise reconnect
  /// silently. Only the visible session holds a socket.
  Future<void> onAppResumed() async {
    final session = _session;
    final current = session?.current;
    if (session == null || current == null) {
      await refreshDirectory();
      return;
    }
    final previousUrl = current.url;
    await refreshDirectory();
    final updated = instanceStore.instance(current.key);
    if (updated != null && updated.url != previousUrl) {
      await connect(updated);
      return;
    }
    await session.connection.resume();
  }

  Future<void> openNotificationTarget({
    required String machineHost,
    required String workspaceId,
    required String convId,
  }) async {
    final key = InstanceKey(
      machineHost,
      workspaceId.isEmpty ? null : workspaceId,
    );
    var inst = instanceStore.instance(key);
    if (inst == null) {
      for (final i in instanceStore.doc.instances) {
        if (i.machineHost == machineHost &&
            (workspaceId.isEmpty || i.workspaceId == workspaceId)) {
          inst = i;
          break;
        }
      }
    }
    if (inst == null) {
      // Unpaired / unknown instance: the picker (or pairing screen) is what
      // the user sees; the current session is kept.
      showInstances();
      return;
    }
    await connect(inst);
    final session = _session!;
    session.state.view(convId);
    session.conversationFocus.value++;
  }

  // -- sessions -----------------------------------------------------------

  /// The kept session for [inst]. A record stored before its first `hello`
  /// has no workspace id yet; it is matched by url.
  RemoteController? _sessionFor(InstanceRecord inst) {
    for (final s in _sessions) {
      final c = s.current!;
      if (c.key == inst.key) return s;
      if (c.machineHost == inst.machineHost &&
          (c.workspaceId == null || inst.workspaceId == null) &&
          c.url == inst.url) {
        return s;
      }
    }
    return null;
  }

  RemoteController _open(InstanceRecord inst) {
    final session = RemoteController(
      connection: _newConnection(),
      instance: inst,
    );
    session.onHello = (hello) => _applyHello(session, hello);
    session.connection.onTokenInvalid = () => _tokenInvalid(session);
    session.state.onPermissionRequested = (request) =>
        onPermissionRequested?.call(request);
    session.state.onStreamingEnded = (ended) =>
        onStreamingEnded?.call(ended);
    // Phase changes drive the pairing screen and the notification context.
    session.connection.addListener(notifyListeners);
    _sessions.add(session);
    return session;
  }

  Future<void> _close(RemoteController session) async {
    if (!_sessions.remove(session)) return;
    _lastShown.remove(session);
    if (_session == session) _session = null;
    session.connection.removeListener(notifyListeners);
    await session.connection.stop();
    session.dispose();
  }

  Future<void> _evictBeyondCap() async {
    while (_sessions.length > maxSessions) {
      RemoteController? oldest;
      for (final s in _sessions) {
        if (s == _session) continue;
        if (oldest == null || _lastShown[s]! < _lastShown[oldest]!) {
          oldest = s;
        }
      }
      if (oldest == null) return;
      await _close(oldest);
    }
  }

  Future<void> _tokenInvalid(RemoteController session) async {
    final host = session.current?.machineHost;
    if (host != null) {
      await instanceStore.markMachineNeedsPairing(host);
      unawaited(relayAlerts.sync(instanceStore.doc));
    }
    // The session is kept: re-pairing reconnects it with its state.
    if (_session == session) {
      _needsPairingHost = host;
      _session = null;
    }
    notifyListeners();
  }

  void _applyHello(RemoteController session, Hello hello) {
    final current = session.current;
    if (current == null) return;
    final updated = current.copyWith(
      workspaceId: hello.workspace.id,
      displayName: hello.workspace.displayName,
    );
    session.updateInstance(updated);
    unawaited(
      instanceStore
          .upsertInstance(updated)
          .then((_) => relayAlerts.sync(instanceStore.doc)),
    );
    final machine = instanceStore.machine(current.machineHost);
    final directoryUrl = hello.machine?.directoryUrl;
    if (machine != null && directoryUrl != null) {
      unawaited(
        instanceStore.upsertMachine(
          machine.copyWith(directoryUrl: directoryUrl),
        ),
      );
    }
    if (session == _session) notifyListeners();
  }

  @override
  void dispose() {
    // Not stopped first: a stop finishing after dispose would notify a
    // disposed connection. Disposing cancels its timers and subscription.
    for (final s in _sessions) {
      s.connection.removeListener(notifyListeners);
      s.dispose();
    }
    _sessions.clear();
    _session = null;
    super.dispose();
  }
}
