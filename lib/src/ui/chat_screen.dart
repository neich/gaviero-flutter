/// The chat view (B4): role-styled bubbles, live streaming, tool rows,
/// scroll-back paging, and connection-state surfaces.
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import 'composer.dart';
import 'conversation_drawer.dart';
import 'feedback.dart';
import 'message_widgets.dart';
import 'permission_card.dart';
import 'review_screen.dart';
import 'shell_screen.dart';
import 'turn_review_card.dart';

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
      final convId = widget.controller.state.viewedId;
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
        final conv = controller.state.viewed;
        final turnReviews = controller.supportsTurnReview;
        final pendingReview = turnReviews && conv != null
            ? controller.state.pendingTurnReviewFor(conv.summary.convId)
            : null;
        final resolvedReview =
            turnReviews && conv != null && pendingReview == null
                ? controller.state
                    .turnReviewResolutionFor(conv.summary.convId)
                : null;
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
              IconButton(
                tooltip: 'Shell sessions',
                icon: const Icon(Icons.terminal),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ShellScreen(controller: controller),
                )),
              ),
              IconButton(
                tooltip: 'Instances',
                icon: const Icon(Icons.dns_outlined),
                onPressed: () => controller.disconnect(),
              ),
              if (controller.state.otherPermissionCount > 0)
                IconButton(
                  tooltip: 'Open permission on another tab',
                  icon: Badge.count(
                    count: controller.state.otherPermissionCount,
                    child: const Icon(Icons.gavel),
                  ),
                  onPressed: () {
                    final other = controller.state.oldestOtherPermission;
                    if (other != null) controller.state.view(other.convId);
                  },
                ),
              if (controller.supportsTurnReview &&
                  controller.state.orphanTurnReviews.isNotEmpty)
                IconButton(
                  key: const Key('orphan-turn-reviews'),
                  tooltip: 'Turn reviews without a conversation tab',
                  icon: Badge.count(
                    count: controller.state.orphanTurnReviews.length,
                    child: const Icon(Icons.fact_check_outlined),
                  ),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) =>
                        OrphanTurnReviewsScreen(controller: controller),
                  )),
                ),
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
              PopupMenuButton<String>(
                onSelected: (choice) async {
                  switch (choice) {
                    case 'follow':
                      controller.state
                          .setFollowDesktop(!controller.state.followDesktop);
                    case 'instances':
                      await controller.disconnect();
                  }
                },
                itemBuilder: (context) => [
                  CheckedPopupMenuItem(
                    value: 'follow',
                    checked: controller.state.followDesktop,
                    child: const Text('Follow desktop'),
                  ),
                  const PopupMenuItem(
                    value: 'instances',
                    child: Text('Instances'),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              ConnectionBanner(
                connection: controller.connection,
                instanceName: controller.current?.displayName,
              ),
              _ConversationTabs(controller: controller),
              if (conv != null) StatusStrip(conv: conv),
              Expanded(
                child: conv == null
                    ? const Center(child: Text('No conversation'))
                    : _MessageList(conv: conv, scroll: _scroll),
              ),
              if (resolvedReview != null)
                TurnReviewResolvedBanner(
                  resolved: resolvedReview,
                  onDismiss: () => controller.state
                      .dismissTurnReviewResolution(conv!.summary.convId),
                ),
              if (pendingReview != null)
                TurnReviewCard(controller: controller, review: pendingReview),
              if (controller.state.viewedPermissions.isNotEmpty)
                PermissionCard(
                  controller: controller,
                  request: controller.state.viewedPermissions.first,
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

class _ConversationTabs extends StatelessWidget {
  final RemoteController controller;
  const _ConversationTabs({required this.controller});

  @override
  Widget build(BuildContext context) {
    final conversations = controller.state.conversations;
    if (conversations.isEmpty) return const SizedBox.shrink();
    final viewedId = controller.state.viewedId;
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final conv in conversations)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onLongPress: () => _showOnDesktop(context, conv.summary.convId),
                child: FilterChip(
                  visualDensity: VisualDensity.compact,
                  selected: conv.summary.convId == viewedId,
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(conv.summary.title,
                          overflow: TextOverflow.ellipsis),
                      if (conv.summary.isStreaming) ...[
                        const SizedBox(width: 6),
                        const SizedBox(
                          width: 8,
                          height: 8,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      ],
                      if (controller.state.openPermissions
                          .any((p) => p.convId == conv.summary.convId)) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.gavel, size: 14),
                      ],
                      if (controller.supportsTurnReview &&
                          controller.state
                              .hasPendingTurnReview(conv.summary.convId)) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.fact_check_outlined, size: 14),
                      ],
                      if (conv.unread > 0) ...[
                        const SizedBox(width: 4),
                        Badge.count(count: conv.unread),
                      ],
                    ],
                  ),
                  onSelected: (_) =>
                      controller.state.view(conv.summary.convId),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showOnDesktop(BuildContext context, String convId) async {
    final outcome = await controller.switchConversation(convId);
    if (context.mounted) showOutcome(context, outcome);
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
  final String? instanceName;

  const ConnectionBanner({
    super.key,
    required this.connection,
    this.instanceName,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String? label, Color color) = switch (connection.phase) {
      ConnectionPhase.connected => (null, Colors.transparent),
      ConnectionPhase.connecting ||
      ConnectionPhase.handshaking =>
        ('Connecting…', scheme.surfaceContainerHigh),
      ConnectionPhase.offline => (
          [
            if (instanceName != null) '$instanceName: ',
            connection.statusDetail ?? 'Instance offline',
          ].join(),
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
