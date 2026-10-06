/// Wires the connection, the mirror state, and instance storage together and
/// exposes the high-level actions the UI calls. Freshness tokens (§3.5) are
/// attached here: `conv_revision` on rename/reset, `proposal_revision` on
/// review actions, `request_id` on permission decisions.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/protocol.dart';
import '../services/directory_client.dart';
import '../services/instance_store.dart';
import '../services/secure_store.dart';
import '../transport/connection.dart';
import 'app_state.dart';

final class RemoteController extends ChangeNotifier {
  final RemoteConnection connection;
  final AppState state;
  final InstanceStore instanceStore;
  final DirectoryClient directoryClient;

  InstanceRecord? _current;
  String? _needsPairingHost;
  final Set<String> _pagesInFlight = {};
  final Set<String> _newestInFlight = {};

  RemoteController({
    RemoteConnection? connection,
    AppState? state,
    InstanceStore? instanceStore,
    DirectoryClient? directoryClient,
  }) : connection = connection ?? RemoteConnection(),
       state = state ?? AppState(),
       instanceStore = instanceStore ?? InstanceStore(),
       directoryClient = directoryClient ?? DirectoryClient() {
    this.connection.onEnvelope = _onEnvelope;
    this.connection.onInstanceChanged = this.state.clear;
    this.connection.onTokenInvalid = () async {
      final host = _current?.machineHost;
      if (host != null) {
        await this.instanceStore.markMachineNeedsPairing(host);
      }
      _needsPairingHost = host;
      _current = null;
      notifyListeners();
    };
    this.state.onNeedNewestPage = (convId) {
      requestNewestPage(convId);
    };
    this.connection.addListener(notifyListeners);
    this.state.addListener(notifyListeners);
  }

  InstanceRecord? get current => _current;
  String? get needsPairingHost => _needsPairingHost;
  bool get isPaired => instanceStore.doc.machines.isNotEmpty;

  /// Loads stored instances, refreshes the machine directory so a TUI that
  /// fell forward to a new port is found, then reconnects to
  /// [StoreDocument.lastInstance] when present.
  Future<bool> initialize() async {
    await instanceStore.load();
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
      ),
    );
    final inst = InstanceRecord(
      machineHost: host,
      workspaceId: config.workspaceId,
      displayName: config.workspace.isEmpty ? host : config.workspace,
      url: config.url,
    );
    await instanceStore.upsertInstance(inst);
    _needsPairingHost = null;
    notifyListeners();
    await connect(inst);
  }

  /// Host + token only — directory refresh fills in running instances.
  Future<void> pairMachineOnly(
    String host,
    String token, {
    int directoryPort = defaultDirectoryPort,
  }) async {
    await instanceStore.upsertMachine(
      MachineRecord(
        host: host,
        token: token,
        directoryUrl: 'https://$host:$directoryPort$instancesPath',
        pairedAt: DateTime.now().toUtc().toIso8601String(),
        needsPairing: false,
      ),
    );
    _needsPairingHost = null;
    notifyListeners();
    await refreshDirectory();
  }

  Future<void> connect(InstanceRecord inst) async {
    final switched = _current?.key != inst.key;
    final moved = _current?.url != inst.url;
    if (switched || moved) {
      await connection.stop();
      if (switched) state.clear();
    }
    _current = inst;
    _needsPairingHost = null;
    await instanceStore.setLastInstance(inst.key);
    notifyListeners();
    final machine = instanceStore.machine(inst.machineHost);
    if (machine == null || machine.needsPairing) return;
    if (!switched &&
        !moved &&
        (connection.isConnected ||
            connection.phase == ConnectionPhase.connecting ||
            connection.phase == ConnectionPhase.handshaking)) {
      return;
    }
    await connection.start(Uri.parse(inst.url), machine.token);
  }

  Future<void> disconnect() async {
    await connection.stop();
    _current = null;
    state.clear();
    notifyListeners();
  }

  Future<void> refreshDirectory() async {
    await directoryClient.refresh(instanceStore);
    notifyListeners();
  }

  Future<void> forgetInstance(InstanceKey key) async {
    if (_current?.key == key) await disconnect();
    await instanceStore.forgetInstance(key);
    notifyListeners();
  }

  Future<void> forgetMachine(String host) async {
    if (_current?.machineHost == host) await disconnect();
    await instanceStore.forgetMachine(host);
    if (_needsPairingHost == host) _needsPairingHost = null;
    notifyListeners();
  }

  /// App resumed from background: a dead socket is routine (the server culls
  /// after 60 s without traffic). Refresh the directory first so a TUI that
  /// moved port while we were away is followed; otherwise reconnect silently.
  Future<void> onAppResumed() async {
    final current = _current;
    if (current == null) {
      await refreshDirectory();
      return;
    }
    final key = current.key;
    final previousUrl = current.url;
    await refreshDirectory();
    final updated = instanceStore.instance(key);
    if (updated != null && updated.url != previousUrl) {
      await connect(updated);
      return;
    }
    await connection.resume();
  }

  void _onEnvelope(ServerEnvelope envelope) {
    if (envelope.payload case final Hello hello) {
      _applyHello(hello);
    }
    state.applyEnvelope(envelope);
  }

  void _applyHello(Hello hello) {
    final current = _current;
    if (current == null) return;
    final updated = current.copyWith(
      workspaceId: hello.workspace.id,
      displayName: hello.workspace.displayName,
    );
    _current = updated;
    unawaited(instanceStore.upsertInstance(updated));
    final machine = instanceStore.machine(current.machineHost);
    final directoryUrl = hello.machine?.directoryUrl;
    if (machine != null && directoryUrl != null) {
      unawaited(
        instanceStore.upsertMachine(
          machine.copyWith(directoryUrl: directoryUrl),
        ),
      );
    }
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
      // Unpaired / unknown instance: drop the current socket so the
      // picker (or pairing screen) is what the user sees.
      if (_current != null) await disconnect();
      return;
    }
    if (_current?.key != inst.key) {
      await connect(inst);
    }
    state.view(convId);
  }

  // -- actions ------------------------------------------------------------

  Future<CommandOutcome> sendPrompt(String text) {
    final convId = state.viewedId;
    if (convId == null) return Future.value(const CommandDropped());
    return connection.send(SendPrompt(convId: convId, text: text));
  }

  Future<CommandOutcome> sendSlash(String line, {required bool confirmed}) {
    final convId = state.viewedId;
    if (convId == null) return Future.value(const CommandDropped());
    return connection.send(
      Slash(convId: convId, line: line, confirmed: confirmed),
    );
  }

  Future<CommandOutcome> interrupt() {
    final conv = state.viewed;
    if (conv == null) return Future.value(const CommandDropped());
    return connection.send(
      Interrupt(
        convId: conv.summary.convId,
        turnId: conv.summary.pendingTurnId,
      ),
    );
  }

  Future<CommandOutcome> newConversation() =>
      connection.send(const NewConversation());

  Future<CommandOutcome> switchConversation(String convId) =>
      connection.send(SwitchConversation(convId: convId));

  Future<CommandOutcome> renameConversation(String convId, String title) {
    final conv = state.conversation(convId);
    if (conv == null) return Future.value(const CommandDropped());
    return connection.send(
      RenameConversation(
        convId: convId,
        convRevision: conv.summary.convRevision,
        title: title,
      ),
    );
  }

  Future<CommandOutcome> resetConversation(String convId) {
    final conv = state.conversation(convId);
    if (conv == null) return Future.value(const CommandDropped());
    return connection.send(
      ResetConversation(
        convId: convId,
        convRevision: conv.summary.convRevision,
      ),
    );
  }

  /// Scroll-back paging (§3.6): one cursor concept, `before_seq =
  /// oldest_seq`, deduped while a page is in flight.
  Future<void> requestOlderMessages(String convId, {int limit = 50}) async {
    final conv = state.conversation(convId);
    final cursor = conv?.oldestSeq;
    if (conv == null || cursor == null || !conv.hasOlderMessages) return;
    if (!_pagesInFlight.add(convId)) return;
    try {
      await connection.send(
        RequestMessages(convId: convId, beforeSeq: cursor, limit: limit),
      );
    } finally {
      _pagesInFlight.remove(convId);
    }
  }

  Future<void> requestNewestPage(String convId, {int limit = 50}) async {
    if (!_newestInFlight.add(convId)) return;
    state.expectNewestPage(convId);
    try {
      final supportsLatest = connection.hello?.supportsLatestPage ?? false;
      await connection.send(
        RequestMessages(
          convId: convId,
          beforeSeq: supportsLatest ? null : legacyNewestPageBeforeSeq,
          limit: limit,
        ),
      );
    } finally {
      _newestInFlight.remove(convId);
    }
  }

  Future<CommandOutcome> permissionDecision(
    String requestId, {
    required bool allow,
    List<List<int>>? answers,
    String? message,
  }) => connection.send(
    PermissionDecision(
      requestId: requestId,
      allow: allow,
      answers: answers,
      message: message,
    ),
  );

  Future<CommandOutcome> reviewAction(
    int proposalId,
    ReviewActionKind action, {
    int? hunkIndex,
  }) {
    final proposal = state.proposal(proposalId);
    if (proposal == null) return Future.value(const CommandDropped());
    return connection.send(
      ReviewAction(
        proposalId: proposalId,
        proposalRevision: proposal.revision,
        action: action,
        hunkIndex: hunkIndex,
      ),
    );
  }

  Future<CommandOutcome> requestProposal(int proposalId) =>
      connection.send(RequestProposal(proposalId: proposalId));

  /// The server advertised [Capability.turnReview]: turn-review frames may
  /// arrive and `turn_review_action` is accepted.
  bool get supportsTurnReview =>
      connection.hello?.hasCapability(Capability.turnReview) ?? false;

  /// Whole-file turn-review decisions (per-hunk is desktop-only). Dropped
  /// without sending on a server lacking [Capability.turnReview]. An
  /// `unknown_turn_review` reply means the review was finalized elsewhere
  /// (usually the desktop) — a benign race; resync so a missed
  /// `turn_review_resolved` cannot leave the conversation looking blocked.
  Future<CommandOutcome> turnReviewAction(
    String turnId,
    TurnReviewActionKind action, {
    String? path,
  }) async {
    if (!supportsTurnReview) return const CommandDropped();
    final outcome = await connection.send(
      TurnReviewAction(turnId: turnId, action: action, path: path),
    );
    if (outcome case CommandFail(:final error)
        when error.code == ErrorCode.unknownTurnReview) {
      unawaited(connection.send(const RequestSnapshot()));
    }
    return outcome;
  }

  /// Workspace paths for an `@` reference; dropped without sending on a
  /// server lacking [Capability.fileCompletions].
  Future<CommandOutcome> requestFileCompletions(String query) {
    if (!(connection.hello?.hasCapability(Capability.fileCompletions) ??
        false)) {
      return Future.value(const CommandDropped());
    }
    return connection.send(RequestFileCompletions(query: query));
  }

  @override
  void dispose() {
    connection.dispose();
    state.dispose();
    super.dispose();
  }
}
