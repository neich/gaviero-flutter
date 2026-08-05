/// The chat view (B4): role-styled bubbles, live streaming, tool rows,
/// scroll-back paging, and connection-state surfaces.
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import 'composer.dart';
import 'conversation_drawer.dart';
import 'message_widgets.dart';
import 'permission_card.dart';
import 'review_screen.dart';

class ChatScreen extends StatefulWidget {
  final RemoteController controller;

  const ChatScreen({super.key, required this.controller});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybePage);
  }

  void _maybePage() {
    // The list is reversed: maxScrollExtent is the oldest end.
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      final convId = widget.controller.state.activeId;
      if (convId != null) {
        widget.controller.requestOlderMessages(convId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final conv = controller.state.active;
        return Scaffold(
          drawer: ConversationDrawer(controller: controller),
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(conv?.summary.title ?? 'Gaviero Remote',
                    style: const TextStyle(fontSize: 17)),
                if (conv?.summary.model != null)
                  Text(conv!.summary.model!,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: Colors.white54)),
              ],
            ),
            actions: [
              if (controller.state.openProposals.isNotEmpty)
                IconButton(
                  tooltip: 'Review proposals',
                  icon: Badge.count(
                    count: controller.state.openProposals.length,
                    child: const Icon(Icons.rule),
                  ),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) =>
                        ReviewListScreen(controller: controller),
                  )),
                ),
            ],
          ),
          body: Column(
            children: [
              ConnectionBanner(connection: controller.connection),
              if (conv != null) StatusStrip(conv: conv),
              Expanded(
                child: conv == null
                    ? const Center(child: Text('No conversation'))
                    : _MessageList(conv: conv, scroll: _scroll),
              ),
              if (controller.state.openPermissions.isNotEmpty)
                PermissionCard(
                  controller: controller,
                  request: controller.state.openPermissions.first,
                ),
              Composer(controller: controller),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class _MessageList extends StatelessWidget {
  final ConversationData conv;
  final ScrollController scroll;

  const _MessageList({required this.conv, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final showStreaming = conv.streamingTurnId != null &&
        (conv.streamingText.isNotEmpty ||
            conv.streamingStatus != null ||
            conv.liveToolCalls.isNotEmpty);
    final messages = conv.messages;
    final headerRows = conv.hasOlderMessages ? 1 : 0;
    final streamingRows = showStreaming ? 1 : 0;
    final total = messages.length + headerRows + streamingRows;
    return ListView.builder(
      controller: scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: total,
      itemBuilder: (context, index) {
        // reversed: index 0 is the newest row.
        if (showStreaming && index == 0) {
          return StreamingBubble(
            text: conv.streamingText,
            status: conv.streamingStatus,
            toolCalls: conv.liveToolCalls,
          );
        }
        final messageIndex = messages.length - 1 - (index - streamingRows);
        if (messageIndex < 0) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        return MessageBubble(message: messages[messageIndex]);
      },
    );
  }
}

/// B10 status surfaces: context pressure, token usage, and cost for the
/// active conversation. Hidden entirely until the server has sent any of
/// them.
class StatusStrip extends StatelessWidget {
  final ConversationData conv;

  const StatusStrip({super.key, required this.conv});

  @override
  Widget build(BuildContext context) {
    final pressure = conv.summary.contextPressure;
    final usage = conv.lastUsage;
    final cost = conv.lastTurnCostUsd;
    if (pressure == null && usage == null && cost == null) {
      return const SizedBox.shrink();
    }
    final labelStyle = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(color: Colors.white54);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          if (pressure != null) ...[
            Expanded(
              flex: 2,
              child: Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: pressure.ratio.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: Colors.white12,
                      color: pressure.ratio > 0.85
                          ? Colors.orangeAccent
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('${(pressure.ratio * 100).round()}%',
                      style: labelStyle),
                ],
              ),
            ),
            const SizedBox(width: 12),
          ],
          if (usage != null) ...[
            Text('▲${_compact(usage.inputTokens)} ▼${_compact(usage.outputTokens)}',
                style: labelStyle),
            const SizedBox(width: 12),
          ],
          if (cost != null)
            Text(
                '\$${cost.toStringAsFixed(3)}'
                ' · Σ\$${conv.sessionCostUsd.toStringAsFixed(2)}',
                style: labelStyle),
        ],
      ),
    );
  }
}

String _compact(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

/// §3.7 surfaces: every abnormal connection state gets a distinct, calm
/// banner. A routine reconnect shows nothing but a subtle progress line.
class ConnectionBanner extends StatelessWidget {
  final RemoteConnection connection;

  const ConnectionBanner({super.key, required this.connection});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String? label, Color color) = switch (connection.phase) {
      ConnectionPhase.connected => (null, Colors.transparent),
      ConnectionPhase.connecting ||
      ConnectionPhase.handshaking =>
        ('Connecting…', scheme.surfaceContainerHigh),
      ConnectionPhase.offline => (
          connection.statusDetail ?? 'Instance offline',
          scheme.surfaceContainerHigh
        ),
      ConnectionPhase.evicted => (
          'Connected on another device.',
          scheme.tertiaryContainer
        ),
      ConnectionPhase.versionMismatch => (
          "App and desktop versions don't match. "
              '${connection.statusDetail ?? ''}',
          scheme.errorContainer
        ),
      ConnectionPhase.unauthorized => (
          connection.statusDetail ?? 'Pairing is no longer valid.',
          scheme.errorContainer
        ),
      ConnectionPhase.disconnected => (
          connection.statusDetail ?? 'Disconnected',
          scheme.surfaceContainerHigh
        ),
    };
    if (label == null) return const SizedBox.shrink();
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(
              switch (connection.phase) {
                ConnectionPhase.evicted => Icons.devices_other,
                ConnectionPhase.unauthorized => Icons.qr_code_scanner,
                ConnectionPhase.versionMismatch => Icons.sync_problem,
                _ => Icons.cloud_off,
              },
              size: 16,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label, maxLines: 2)),
          ],
        ),
      ),
    );
  }
}
