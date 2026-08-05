/// Command-outcome surfaces. Losing a per-entity freshness race (§3.5) is
/// normal, not an error — stale outcomes get calm, specific messages and
/// the UI refreshes from the state the server already pushed.
library;

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import '../transport/connection.dart';

void showOutcome(
  BuildContext context,
  CommandOutcome outcome, {
  Map<ErrorCode, String> staleMessages = const {},
}) {
  final String? message = switch (outcome) {
    CommandOk() => null,
    CommandDropped() => 'Connection lost — the command was not delivered.',
    CommandFail(:final error) => staleMessages[error.code] ??
        switch (error.code) {
          ErrorCode.staleConversation =>
            'The desktop changed this conversation first — try again.',
          ErrorCode.staleProposal =>
            'The desktop changed this proposal — review the refreshed hunks.',
          ErrorCode.staleRequest => null, // Desktop answered first: silent.
          ErrorCode.conversationStreaming =>
            'The agent is still responding — interrupt it first.',
          ErrorCode.rateLimited => 'Slow down — too many commands.',
          _ => error.message,
        },
  };
  if (message == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
