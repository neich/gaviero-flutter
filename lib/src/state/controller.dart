/// Wires the connection, the mirror state, and pairing storage together and
/// exposes the high-level actions the UI calls. Freshness tokens (§3.5) are
/// attached here: `conv_revision` on rename/reset, `proposal_revision` on
/// review actions, `request_id` on permission decisions.
library;

import 'package:flutter/foundation.dart';

import '../protocol/protocol.dart';
import '../services/secure_store.dart';
import '../transport/connection.dart';
import 'app_state.dart';

final class RemoteController extends ChangeNotifier {
  final RemoteConnection connection;
  final AppState state;
  final PairingStore pairingStore;

  PairingConfig? _pairing;
  final Set<String> _pagesInFlight = {};

  RemoteController({
    RemoteConnection? connection,
    AppState? state,
    PairingStore? pairingStore,
  })  : connection = connection ?? RemoteConnection(),
        state = state ?? AppState(),
        pairingStore = pairingStore ?? const PairingStore() {
    this.connection.onEnvelope = this.state.applyEnvelope;
    this.connection.onInstanceChanged = this.state.clear;
    this.connection.onTokenInvalid = () async {
      await this.pairingStore.clear();
      _pairing = null;
      notifyListeners();
    };
    this.state.onNeedSnapshot = () {
      this.connection.send(const RequestSnapshot());
    };
    this.connection.addListener(notifyListeners);
    this.state.addListener(notifyListeners);
  }

  PairingConfig? get pairing => _pairing;
  bool get isPaired => _pairing != null;

  /// Loads stored pairing and connects if present. Returns whether paired.
  Future<bool> initialize() async {
    _pairing = await pairingStore.load();
    notifyListeners();
    if (_pairing == null) return false;
    await _connectWithPairing();
    return true;
  }

  Future<void> pair(PairingConfig config) async {
    await pairingStore.save(config);
    _pairing = config;
    notifyListeners();
    await _connectWithPairing();
  }

  Future<void> unpair() async {
    await connection.stop();
    await pairingStore.clear();
    _pairing = null;
    notifyListeners();
  }

  Future<void> _connectWithPairing() async {
    final pairing = _pairing;
    if (pairing == null) return;
    await connection.start(Uri.parse(pairing.url), pairing.token);
  }

  /// App resumed from background: a dead socket is routine (the server culls
  /// after 60 s without traffic). Reconnect silently.
  Future<void> onAppResumed() => connection.resume();

  // -- actions ------------------------------------------------------------

  Future<CommandOutcome> sendPrompt(String text) {
    final convId = state.activeId;
    if (convId == null) return Future.value(const CommandDropped());
    return connection.send(SendPrompt(convId: convId, text: text));
  }

  Future<CommandOutcome> sendSlash(String line, {required bool confirmed}) {
    final convId = state.activeId;
    if (convId == null) return Future.value(const CommandDropped());
    return connection
        .send(Slash(convId: convId, line: line, confirmed: confirmed));
  }

  Future<CommandOutcome> interrupt() {
    final conv = state.active;
    if (conv == null) return Future.value(const CommandDropped());
    return connection.send(Interrupt(
      convId: conv.summary.convId,
      turnId: conv.summary.pendingTurnId,
    ));
  }

  Future<CommandOutcome> newConversation() =>
      connection.send(const NewConversation());

  Future<CommandOutcome> switchConversation(String convId) =>
      connection.send(SwitchConversation(convId: convId));

  Future<CommandOutcome> renameConversation(String convId, String title) {
    final conv = state.conversation(convId);
    if (conv == null) return Future.value(const CommandDropped());
    return connection.send(RenameConversation(
      convId: convId,
      convRevision: conv.summary.convRevision,
      title: title,
    ));
  }

  Future<CommandOutcome> resetConversation(String convId) {
    final conv = state.conversation(convId);
    if (conv == null) return Future.value(const CommandDropped());
    return connection.send(ResetConversation(
      convId: convId,
      convRevision: conv.summary.convRevision,
    ));
  }

  /// Scroll-back paging (§3.6): one cursor concept, `before_seq =
  /// oldest_seq`, deduped while a page is in flight.
  Future<void> requestOlderMessages(String convId, {int limit = 50}) async {
    final conv = state.conversation(convId);
    final cursor = conv?.oldestSeq;
    if (conv == null || cursor == null || !conv.hasOlderMessages) return;
    if (!_pagesInFlight.add(convId)) return;
    try {
      await connection.send(RequestMessages(
        convId: convId,
        beforeSeq: cursor,
        limit: limit,
      ));
    } finally {
      _pagesInFlight.remove(convId);
    }
  }

  Future<CommandOutcome> permissionDecision(
    String requestId, {
    required bool allow,
    List<List<int>>? answers,
    String? message,
  }) =>
      connection.send(PermissionDecision(
        requestId: requestId,
        allow: allow,
        answers: answers,
        message: message,
      ));

  Future<CommandOutcome> reviewAction(
    int proposalId,
    ReviewActionKind action, {
    int? hunkIndex,
  }) {
    final proposal = state.proposal(proposalId);
    if (proposal == null) return Future.value(const CommandDropped());
    return connection.send(ReviewAction(
      proposalId: proposalId,
      proposalRevision: proposal.revision,
      action: action,
      hunkIndex: hunkIndex,
    ));
  }

  Future<CommandOutcome> requestProposal(int proposalId) =>
      connection.send(RequestProposal(proposalId: proposalId));

  @override
  void dispose() {
    connection.dispose();
    state.dispose();
    super.dispose();
  }
}
