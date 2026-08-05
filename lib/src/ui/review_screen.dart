/// Hunk-level write-gate review (B7). The client renders rows, it does not
/// diff: hunks arrive structured from the server, review actions send
/// `hunk_index` + `proposal_revision`, and the server applies them to its
/// own copy — file content never travels back. A truncated hunk is still
/// fully reviewable and the elision is rendered honestly.
library;

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import '../state/app_state.dart';
import '../state/controller.dart';
import 'feedback.dart';
import 'theme.dart';

class ReviewListScreen extends StatelessWidget {
  final RemoteController controller;

  const ReviewListScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final proposals = controller.state.openProposals;
        return Scaffold(
          appBar: AppBar(title: const Text('Write-gate review')),
          body: proposals.isEmpty
              ? const Center(child: Text('No open proposals'))
              : ListView(
                  children: [
                    for (final proposal in proposals)
                      _ProposalTile(
                          controller: controller, proposal: proposal),
                  ],
                ),
        );
      },
    );
  }
}

class _ProposalTile extends StatelessWidget {
  final RemoteController controller;
  final ProposalData proposal;

  const _ProposalTile({required this.controller, required this.proposal});

  @override
  Widget build(BuildContext context) {
    final summary = proposal.summary;
    final detail = proposal.detail;
    final hunkCount = detail?.hunks.length ?? summary?.hunkCount ?? 0;
    final subtitleParts = <String>[
      '$hunkCount hunk${hunkCount == 1 ? '' : 's'}',
      if (summary != null) '+${summary.addedLines} −${summary.removedLines}',
      if (proposal.isDeletion) 'deletes file',
      proposal.status.wire,
    ];
    final conflicts =
        detail?.conflictsWith ?? summary?.conflictsWith ?? const [];
    return ListTile(
      leading: Icon(
        proposal.isDeletion ? Icons.delete_outline : Icons.difference_outlined,
        color: Theme.of(context).colorScheme.secondary,
      ),
      title: Text(proposal.path,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        subtitleParts.join(' · '),
        if (conflicts.isNotEmpty)
          'conflicts with #${conflicts.join(', #')}',
      ].join('\n')),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (context) => ProposalScreen(
            controller: controller, proposalId: proposal.id),
      )),
    );
  }
}

class ProposalScreen extends StatefulWidget {
  final RemoteController controller;
  final int proposalId;

  const ProposalScreen({
    super.key,
    required this.controller,
    required this.proposalId,
  });

  @override
  State<ProposalScreen> createState() => _ProposalScreenState();
}

class _ProposalScreenState extends State<ProposalScreen> {
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // A proposal first seen as a snapshot summary has no hunk text yet
    // (§3.6): fetch the detail on demand.
    final proposal = widget.controller.state.proposal(widget.proposalId);
    if (proposal != null && proposal.detail == null) {
      widget.controller.requestProposal(widget.proposalId);
    }
  }

  Future<void> _act(ReviewActionKind action, {int? hunkIndex}) async {
    setState(() => _sending = true);
    final outcome = await widget.controller
        .reviewAction(widget.proposalId, action, hunkIndex: hunkIndex);
    if (mounted) {
      setState(() => _sending = false);
      // stale_proposal: the store already holds the refreshed proposal from
      // proposal_updated; the message tells the user why their tap did not
      // stick, and the rebuilt screen shows the current hunks.
      showOutcome(context, outcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final proposal = widget.controller.state.proposal(widget.proposalId);
        if (proposal == null) {
          // Finalized (or removed) while open — nothing left to review.
          return Scaffold(
            appBar: AppBar(title: const Text('Proposal')),
            body: const Center(child: Text('This proposal was finalized.')),
          );
        }
        final detail = proposal.detail;
        return Scaffold(
          appBar: AppBar(
            title: Text(proposal.path,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          body: detail == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.only(bottom: 90),
                  children: [
                    if (proposal.isDeletion)
                      const ListTile(
                        leading:
                            Icon(Icons.delete_outline, color: Colors.orange),
                        title: Text('This proposal deletes the file.'),
                      ),
                    for (final hunk in detail.hunks)
                      _HunkCard(
                        hunk: hunk,
                        sending: _sending,
                        onAccept: () => _act(ReviewActionKind.acceptHunk,
                            hunkIndex: hunk.index),
                        onReject: () => _act(ReviewActionKind.rejectHunk,
                            hunkIndex: hunk.index),
                      ),
                  ],
                ),
          bottomNavigationBar: detail == null
              ? null
              : BottomAppBar(
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: _sending
                            ? null
                            : () => _act(ReviewActionKind.rejectAll),
                        child: const Text('Reject all'),
                      ),
                      TextButton(
                        onPressed: _sending
                            ? null
                            : () => _act(ReviewActionKind.acceptAll),
                        child: const Text('Accept all'),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _sending
                            ? null
                            : () => _act(ReviewActionKind.finalize),
                        icon: const Icon(Icons.done_all),
                        label: const Text('Finalize'),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _HunkCard extends StatelessWidget {
  final Hunk hunk;
  final bool sending;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _HunkCard({
    required this.hunk,
    required this.sending,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = switch (hunk.status) {
      HunkStatus.pending => Colors.white38,
      HunkStatus.accepted => Colors.lightGreenAccent,
      HunkStatus.rejected => Colors.orangeAccent,
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (hunk.hunkType) {
                    HunkType.added => Icons.add_circle_outline,
                    HunkType.removed => Icons.remove_circle_outline,
                    HunkType.modified => Icons.change_circle_outlined,
                  },
                  size: 16,
                  color: scheme.secondary,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(hunk.description)),
                Text(hunk.status.wire,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: statusColor)),
              ],
            ),
            const SizedBox(height: 6),
            if (hunk.truncated)
              // Honest elision: never imply the user reviewed text they
              // never saw. The action still applies to the full hunk,
              // assembled server-side.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: codeBackground,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Hunk text not shown (over 64 KiB per side). Accepting or '
                  'rejecting applies to the full change, assembled on the '
                  'desktop — review it there if you need to see it.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.white54),
                ),
              )
            else ...[
              if (hunk.originalText.isNotEmpty)
                _DiffSide(
                  label:
                      '− lines ${hunk.originalRange.startLine + 1}–${hunk.originalRange.endLine + 1}',
                  text: hunk.originalText,
                  tint: const Color(0x33FF5252),
                ),
              if (hunk.proposedText.isNotEmpty)
                _DiffSide(
                  label:
                      '+ lines ${hunk.proposedRange.startLine + 1}–${hunk.proposedRange.endLine + 1}',
                  text: hunk.proposedText,
                  tint: const Color(0x2669F0AE),
                ),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: sending ? null : onReject,
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 4),
                FilledButton.tonal(
                  onPressed: sending ? null : onAccept,
                  child: const Text('Accept'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DiffSide extends StatelessWidget {
  final String label;
  final String text;
  final Color tint;

  const _DiffSide({
    required this.label,
    required this.text,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Colors.white54)),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            child: Text(
              text,
              style:
                  const TextStyle(fontFamily: codeFontFamily, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
