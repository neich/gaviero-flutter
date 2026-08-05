/// Conversation tabs (B5): a drawer mirroring `snapshot.conversations`,
/// upserted live by `conversation_state_changed` / `conversation_removed`.
/// Rename and reset carry `conv_revision`; losing that race surfaces as a
/// calm retry message, never a lost edit.
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/controller.dart';
import 'feedback.dart';

class ConversationDrawer extends StatelessWidget {
  final RemoteController controller;

  const ConversationDrawer({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final conversations = controller.state.conversations;
            final activeId = controller.state.activeId;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      Text('Conversations',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      IconButton(
                        tooltip: 'New conversation',
                        icon: const Icon(Icons.add),
                        onPressed: () async {
                          final outcome = await controller.newConversation();
                          if (context.mounted) showOutcome(context, outcome);
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    children: [
                      for (final conv in conversations)
                        _ConversationTile(
                          controller: controller,
                          conv: conv,
                          isActive: conv.summary.convId == activeId,
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final RemoteController controller;
  final ConversationData conv;
  final bool isActive;

  const _ConversationTile({
    required this.controller,
    required this.conv,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final summary = conv.summary;
    final pressure = summary.contextPressure;
    return ListTile(
      selected: isActive,
      title: Row(
        children: [
          Expanded(
            child: Text(summary.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (summary.isStreaming)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (summary.lastMessagePreview != null)
            Text(summary.lastMessagePreview!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          Row(
            children: [
              if (summary.model != null)
                Text(summary.model!,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.white38)),
              if (summary.autoApprove)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text('auto-approve',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.tertiary)),
                ),
            ],
          ),
          if (pressure != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                value: pressure.ratio.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: Colors.white12,
              ),
            ),
        ],
      ),
      onTap: () async {
        Navigator.of(context).pop();
        final outcome = await controller
            .switchConversation(summary.convId);
        if (context.mounted) showOutcome(context, outcome);
      },
      trailing: PopupMenuButton<String>(
        onSelected: (choice) => switch (choice) {
          'rename' => _rename(context),
          'reset' => _reset(context),
          _ => null,
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'reset', child: Text('Reset')),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final text = TextEditingController(text: conv.summary.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename conversation'),
        content: TextField(controller: text, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(text.text.trim()),
              child: const Text('Rename')),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    final outcome =
        await controller.renameConversation(conv.summary.convId, title);
    if (context.mounted) showOutcome(context, outcome);
  }

  Future<void> _reset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset conversation?'),
        content: const Text(
            'This clears the conversation on the desktop as well.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true) return;
    final outcome =
        await controller.resetConversation(conv.summary.convId);
    if (context.mounted) showOutcome(context, outcome);
  }
}
