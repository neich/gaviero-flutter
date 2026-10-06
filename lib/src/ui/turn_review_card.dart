/// Mandatory turn review (protocol 1.2, `turn_review`). After a chat turn
/// changes files on disk the desktop holds the conversation's next prompt
/// until every file is decided. Four decisions, each applied at once on the
/// desktop: Accept / Reject one file, Accept all / Reject all for the files
/// still pending. Reject goes back to the pre-prompt version. Decisions are
/// final; a repeat is harmless, and a review the desktop finished first
/// (`unknown_turn_review`) is a calm, benign race.
library;

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import '../state/controller.dart';
import 'feedback.dart';

class TurnReviewCard extends StatefulWidget {
  final RemoteController controller;
  final TurnReview review;

  const TurnReviewCard({
    super.key,
    required this.controller,
    required this.review,
  });

  @override
  State<TurnReviewCard> createState() => _TurnReviewCardState();
}

class _TurnReviewCardState extends State<TurnReviewCard> {
  bool _sending = false;

  @override
  void didUpdateWidget(TurnReviewCard old) {
    super.didUpdateWidget(old);
    if (old.review.turnId != widget.review.turnId) _sending = false;
  }

  Future<void> _act(TurnReviewActionKind action, {String? path}) async {
    setState(() => _sending = true);
    final outcome = await widget.controller
        .turnReviewAction(widget.review.turnId, action, path: path);
    if (mounted) {
      setState(() => _sending = false);
      showOutcome(context, outcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    final review = widget.review;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // An outcome this client does not know is shown neutrally: no nudge.
    final outcomeText = switch (review.outcome) {
      TurnOutcome.cancelled => 'This turn was cancelled',
      TurnOutcome.failed => 'This turn failed',
      TurnOutcome.completed || TurnOutcome.unknown => null,
    };
    final undecided =
        review.files.where((f) => f.decision == TurnFileDecision.pending);
    final anyRejectable = undecided.any((f) => f.revertible);
    final count = review.files.length;
    final left = undecided.length;
    return Material(
      key: const Key('turn-review-card'),
      color: scheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.55),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.fact_check_outlined,
                      size: 18, color: scheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Review changes · $left of $count left',
                      style: textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Accept or reject each file — reject goes back to the '
                'pre-prompt version. The next prompt is held until every '
                'file is decided.',
                style: textTheme.bodySmall?.copyWith(color: Colors.white54),
              ),
              if (outcomeText != null)
                _Notice(
                  key: const Key('turn-review-outcome'),
                  icon: Icons.report_outlined,
                  color: scheme.errorContainer,
                  text: '$outcomeText — its changes may be incomplete. '
                      'Consider Reject all.',
                ),
              for (final warning in review.warnings)
                _Notice(
                  icon: Icons.warning_amber_outlined,
                  color: scheme.tertiaryContainer,
                  text: warning,
                ),
              const SizedBox(height: 6),
              for (final file in review.files)
                _FileRow(
                  file: file,
                  sending: _sending,
                  onAccept: () =>
                      _act(TurnReviewActionKind.keepFile, path: file.path),
                  onReject: () =>
                      _act(TurnReviewActionKind.revertFile, path: file.path),
                ),
              const SizedBox(height: 4),
              // The whole turn: applies to every file not decided yet.
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _sending || !anyRejectable
                          ? null
                          : () => _act(TurnReviewActionKind.revertAll),
                      child: const Text('Reject all'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _sending || left == 0
                          ? null
                          : () => _act(TurnReviewActionKind.keepAll),
                      child: const Text('Accept all'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _Notice({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  final TurnReviewFile file;
  final bool sending;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _FileRow({
    required this.file,
    required this.sending,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final badgeColor = switch (file.change) {
      TurnFileChange.added => Colors.lightGreenAccent,
      TurnFileChange.modified => scheme.secondary,
      TurnFileChange.deleted => Colors.orangeAccent,
      TurnFileChange.unknown => Colors.white54,
    };
    // Decisions are final once taken (a reject is already on disk), so only
    // an undecided file offers Accept / Reject.
    final pending = file.decision == TurnFileDecision.pending;
    final (decisionLabel, decisionColor) = switch (file.decision) {
      TurnFileDecision.pending => ('', Colors.white54),
      TurnFileDecision.keep => ('accepted', Colors.lightGreenAccent),
      TurnFileDecision.revert => ('rejected', Colors.orangeAccent),
      TurnFileDecision.revertHunks => ('partially reverted', Colors.orangeAccent),
      TurnFileDecision.unknown => ('decided on desktop', Colors.white54),
    };
    final flags = <String>[
      if (file.overlapWith.isNotEmpty) 'overlaps another turn',
      if (!file.revertible) 'can only be accepted',
      if (file.binary) 'binary',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 20,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  decoration: BoxDecoration(
                    border: Border.all(color: badgeColor),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    file.change.badge,
                    style: textTheme.labelSmall?.copyWith(color: badgeColor),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(file.path,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            if (flags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 28),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final flag in flags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: flag == 'can only be accepted'
                              ? scheme.errorContainer
                              : scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(flag, style: textTheme.labelSmall),
                      ),
                  ],
                ),
              ),
            Row(
              children: [
                const SizedBox(width: 28),
                Expanded(
                  child: Text(
                    decisionLabel,
                    style:
                        textTheme.labelSmall?.copyWith(color: decisionColor),
                  ),
                ),
                if (pending) ...[
                  TextButton(
                    onPressed: sending || !file.revertible ? null : onReject,
                    child: const Text('Reject'),
                  ),
                  TextButton(
                    onPressed: sending ? null : onAccept,
                    child: const Text('Accept'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Pending reviews no conversation tab shows (no `conv_id`, or a conversation
/// this client does not have). They still exist on the desktop, so the phone
/// lists them here rather than letting them vanish. Closes itself when the
/// last one is finalized.
class OrphanTurnReviewsScreen extends StatelessWidget {
  final RemoteController controller;

  const OrphanTurnReviewsScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final reviews = controller.state.orphanTurnReviews;
        return Scaffold(
          appBar: AppBar(title: const Text('Turn reviews')),
          body: reviews.isEmpty
              ? const Center(child: Text('No pending turn reviews'))
              : ListView(
                  children: [
                    for (final review in reviews) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                        child: Text(
                          review.convId == null
                              ? 'Turn ${review.turnId}'
                              : 'Conversation ${review.convId} (not open)',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                      TurnReviewCard(
                        key: ValueKey(review.turnId),
                        controller: controller,
                        review: review,
                      ),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

/// Shown after `turn_review_resolved` until dismissed or a new review opens:
/// what was kept / reverted, and any decision the desktop could not apply.
class TurnReviewResolvedBanner extends StatelessWidget {
  final TurnReviewResolved resolved;
  final VoidCallback onDismiss;

  const TurnReviewResolvedBanner({
    super.key,
    required this.resolved,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final failed = resolved.failed;
    return Material(
      key: const Key('turn-review-resolved'),
      color: failed.isEmpty
          ? scheme.surfaceContainerHigh
          : scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                failed.isEmpty ? Icons.check_circle_outline : Icons.error_outline,
                size: 16,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Review done: ${resolved.kept} accepted, '
                    '${resolved.reverted} rejected'
                    '${failed.isEmpty ? '' : ', ${failed.length} failed'}',
                    style: textTheme.bodySmall,
                  ),
                  for (final line in failed)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('• $line', style: textTheme.bodySmall),
                    ),
                  if (failed.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Those files were left unchanged — resolve them on '
                        'the desktop if needed.',
                        style: textTheme.bodySmall
                            ?.copyWith(color: Colors.white70),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
