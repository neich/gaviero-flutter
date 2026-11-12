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
import 'turn_review_card.dart';

class ChatScreen extends StatefulWidget {
  final RemoteController controller;

  const ChatScreen({super.key, required this.controller});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll = ScrollController();

  /// True once the list is scrolled up away from the newest row, which shows
  /// the jump-to-latest button.
  final _awayFromLatest = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybePage);
    _scroll.addListener(_trackLatest);
  }

  void _trackLatest() {
    // Reversed list: offset 0 is the newest row.
    _awayFromLatest.value = _scroll.position.pixels > 240;
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
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
            ? controller.state.turnReviewResolutionFor(conv.summary.convId)
            : null;
        final permission = controller.state.viewedPermissions.isEmpty
            ? null
            : controller.state.viewedPermissions.first;
        // What the agent is waiting on is shown as the newest rows of the
        // message list, not docked below it: the reply explaining a change
        // or a question then scrolls together with the card, and a long
        // card never squeezes the conversation out of view.
        final actionRows = <Widget>[
          if (pendingReview != null)
            Padding(
              key: ValueKey('row-turn-review-${pendingReview.turnId}'),
              padding: const EdgeInsets.only(top: 6),
              child: TurnReviewCard(
                controller: controller,
                review: pendingReview,
              ),
            ),
          if (permission != null)
            Padding(
              key: ValueKey('row-permission-${permission.requestId}'),
              padding: const EdgeInsets.only(top: 6),
              child: PermissionCard(
                controller: controller,
                request: permission,
              ),
            ),
        ];
        // The tab strip already names the conversation, so the title is the
        // instance (workspace / repo folder) this screen is connected to.
        final instanceName = controller.current?.displayName;
        final model = conv?.summary.model;
        return Scaffold(
          drawer: ConversationDrawer(controller: controller),
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  instanceName == null || instanceName.isEmpty
                      ? 'Gaviero Remote'
                      : instanceName,
                  key: const Key('chat-title'),
                  style: const TextStyle(fontSize: 17),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (model != null && model.isNotEmpty)
                  Text(
                    model,
                    key: const Key('chat-title-model'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: Colors.white54),
                  ),
              ],
            ),
            // Files, Shells and the instance picker live in the home
            // screen's section bar.
            actions: [
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
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          OrphanTurnReviewsScreen(controller: controller),
                    ),
                  ),
                ),
              if (controller.state.openProposals.isNotEmpty)
                IconButton(
                  tooltip: 'Review proposals',
                  icon: Badge.count(
                    count: controller.state.openProposals.length,
                    child: const Icon(Icons.rule),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          ReviewListScreen(controller: controller),
                    ),
                  ),
                ),
              PopupMenuButton<String>(
                onSelected: (choice) {
                  switch (choice) {
                    case 'follow':
                      controller.state.setFollowDesktop(
                        !controller.state.followDesktop,
                      );
                  }
                },
                itemBuilder: (context) => [
                  CheckedPopupMenuItem(
                    value: 'follow',
                    checked: controller.state.followDesktop,
                    child: const Text('Follow desktop'),
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
                    : Stack(
                        children: [
                          _MessageList(
                            conv: conv,
                            scroll: _scroll,
                            actionRows: actionRows,
                          ),
                          Positioned(
                            right: 12,
                            bottom: 12,
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _awayFromLatest,
                              builder: (context, away, _) => away
                                  ? FloatingActionButton.small(
                                      key: const Key('jump-to-latest'),
                                      heroTag: null,
                                      tooltip: actionRows.isEmpty
                                          ? 'Jump to latest'
                                          : 'Back to the pending card',
                                      onPressed: _jumpToLatest,
                                      child: Badge(
                                        isLabelVisible: actionRows.isNotEmpty,
                                        smallSize: 8,
                                        child: const Icon(
                                          Icons.arrow_downward,
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ],
                      ),
              ),
              if (resolvedReview != null)
                TurnReviewResolvedBanner(
                  resolved: resolvedReview,
                  onDismiss: () => controller.state.dismissTurnReviewResolution(
                    conv!.summary.convId,
                  ),
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
    _awayFromLatest.dispose();
    super.dispose();
  }
}

class _MessageList extends StatelessWidget {
  final ConversationData conv;
  final ScrollController scroll;

  /// Cards the agent is waiting on (turn review, permission / question),
  /// oldest first, each with a stable key. They are the newest rows, below
  /// the streaming bubble.
  final List<Widget> actionRows;

  const _MessageList({
    required this.conv,
    required this.scroll,
    this.actionRows = const [],
  });

  static const _streamingKey = ValueKey('row-streaming');

  @override
  Widget build(BuildContext context) {
    final showStreaming =
        conv.streamingTurnId != null &&
        (conv.streamingText.isNotEmpty ||
            conv.streamingStatus != null ||
            conv.liveToolCalls.isNotEmpty);
    final messages = conv.messages;
    final headerRows = conv.hasOlderMessages ? 1 : 0;
    final actionCount = actionRows.length;
    final streamingRows = showStreaming ? 1 : 0;
    final leadRows = actionCount + streamingRows;
    final total = messages.length + headerRows + leadRows;
    return ListView.builder(
      key: const Key('message-list'),
      controller: scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: total,
      // A card appearing or going away shifts every index; follow the keyed
      // rows so a card keeps its picked answers and the bubble its state.
      findChildIndexCallback: (key) {
        for (var i = 0; i < actionCount; i++) {
          if (actionRows[i].key == key) return actionCount - 1 - i;
        }
        if (key == _streamingKey && showStreaming) return actionCount;
        return null;
      },
      itemBuilder: (context, index) {
        // reversed: index 0 is the newest row.
        if (index < actionCount) return actionRows[actionCount - 1 - index];
        if (showStreaming && index == actionCount) {
          return StreamingBubble(
            key: _streamingKey,
            text: conv.streamingText,
            status: conv.streamingStatus,
            toolCalls: conv.liveToolCalls,
          );
        }
        final messageIndex = messages.length - 1 - (index - leadRows);
        if (messageIndex < 0) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        // Keyed so a bubble's unfolded thinking state never carries over to
        // whichever message lands on this row next.
        final message = messages[messageIndex];
        return MessageBubble(key: ValueKey(message.seq), message: message);
      },
    );
  }
}

class _ConversationTabs extends StatefulWidget {
  final RemoteController controller;
  const _ConversationTabs({required this.controller});

  @override
  State<_ConversationTabs> createState() => _ConversationTabsState();
}

class _ConversationTabsState extends State<_ConversationTabs> {
  final _scroll = ScrollController();
  String? _shownViewedId;

  RemoteController get controller => widget.controller;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Viewed first, then streaming, then the rest, most recent first
    // (AppState.tabOrder).
    final conversations = controller.state.tabOrder;
    if (conversations.isEmpty) return const SizedBox.shrink();
    final viewedId = controller.state.viewedId;
    if (viewedId != _shownViewedId) {
      _shownViewedId = viewedId;
      // The newly viewed tab moved to the far left; bring it into view.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients && _scroll.offset != 0) {
          _scroll.animateTo(
            0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
    return SizedBox(
      height: 48,
      child: ListView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final conv in conversations)
            Padding(
              key: ValueKey('conv-tab-${conv.summary.convId}'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onLongPress: () => _showOnDesktop(context, conv.summary.convId),
                child: FilterChip(
                  visualDensity: VisualDensity.compact,
                  selected: conv.summary.convId == viewedId,
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(conv.summary.title, overflow: TextOverflow.ellipsis),
                      if (conv.summary.isStreaming) ...[
                        const SizedBox(width: 6),
                        const SizedBox(
                          width: 8,
                          height: 8,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      ],
                      if (controller.state.openPermissions.any(
                        (p) => p.convId == conv.summary.convId,
                      )) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.gavel, size: 14),
                      ],
                      if (controller.supportsTurnReview &&
                          controller.state.hasPendingTurnReview(
                            conv.summary.convId,
                          )) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.fact_check_outlined, size: 14),
                      ],
                      if (conv.unread > 0) ...[
                        const SizedBox(width: 4),
                        Badge.count(count: conv.unread),
                      ],
                    ],
                  ),
                  onSelected: (_) => controller.state.view(conv.summary.convId),
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
    final labelStyle = Theme.of(context).textTheme.labelSmall
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
                  Text('${(pressure.ratio * 100).round()}%', style: labelStyle),
                ],
              ),
            ),
            const SizedBox(width: 12),
          ],
          if (usage != null) ...[
            Text(
              '▲${_compact(usage.inputTokens)} ▼${_compact(usage.outputTokens)}',
              style: labelStyle,
            ),
            const SizedBox(width: 12),
          ],
          if (cost != null)
            Text(
              '\$${cost.toStringAsFixed(3)}'
              ' · Σ\$${conv.sessionCostUsd.toStringAsFixed(2)}',
              style: labelStyle,
            ),
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
      ConnectionPhase.connecting || ConnectionPhase.handshaking => (
        'Connecting…',
        scheme.surfaceContainerHigh,
      ),
      ConnectionPhase.offline => (
        [
          if (instanceName != null) '$instanceName: ',
          connection.statusDetail ?? 'Instance offline',
        ].join(),
        scheme.surfaceContainerHigh,
      ),
      ConnectionPhase.evicted => (
        'Connected on another device.',
        scheme.tertiaryContainer,
      ),
      ConnectionPhase.versionMismatch => (
        "App and desktop versions don't match. "
            '${connection.statusDetail ?? ''}',
        scheme.errorContainer,
      ),
      ConnectionPhase.unauthorized => (
        connection.statusDetail ?? 'Pairing is no longer valid.',
        scheme.errorContainer,
      ),
      ConnectionPhase.disconnected => (
        connection.statusDetail ?? 'Disconnected',
        scheme.surfaceContainerHigh,
      ),
    };
    if (label == null) return const SizedBox.shrink();
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(switch (connection.phase) {
              ConnectionPhase.evicted => Icons.devices_other,
              ConnectionPhase.unauthorized => Icons.qr_code_scanner,
              ConnectionPhase.versionMismatch => Icons.sync_problem,
              _ => Icons.cloud_off,
            }, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(label, maxLines: 2)),
          ],
        ),
      ),
    );
  }
}
