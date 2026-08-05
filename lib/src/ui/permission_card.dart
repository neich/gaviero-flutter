/// Approvals (B6). A permission decision cannot change what executes: the
/// displayed `input` is read-only, answers travel as option indices
/// (`answers: [[i]]`), never a rebuilt tool-input document, and the server
/// reconstructs the input itself. A request answered on the desktop first
/// (`permission_closed` / `stale_request`) dismisses without an error —
/// losing that race is normal.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import '../state/controller.dart';
import 'feedback.dart';
import 'theme.dart';

class PermissionCard extends StatefulWidget {
  final RemoteController controller;
  final PermissionRequest request;

  const PermissionCard({
    super.key,
    required this.controller,
    required this.request,
  });

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  late List<Set<int>> _selections;
  bool _sending = false;
  bool _showDenyNote = false;
  final _denyNote = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initSelections();
  }

  @override
  void didUpdateWidget(PermissionCard old) {
    super.didUpdateWidget(old);
    if (old.request.requestId != widget.request.requestId) {
      _initSelections();
      _sending = false;
      _showDenyNote = false;
      _denyNote.clear();
    }
  }

  void _initSelections() {
    _selections = [
      for (final _ in widget.request.ask?.questions ?? <AskQuestion>[])
        <int>{},
    ];
  }

  Ask? get _ask => widget.request.ask;

  bool get _answersComplete {
    final ask = _ask;
    if (ask == null) return true;
    for (var i = 0; i < ask.questions.length; i++) {
      if (!ask.questions[i].multiSelect && _selections[i].length != 1) {
        return false;
      }
    }
    return true;
  }

  Future<void> _decide(bool allow) async {
    setState(() => _sending = true);
    final ask = _ask;
    final outcome = await widget.controller.permissionDecision(
      widget.request.requestId,
      allow: allow,
      answers: allow && ask != null
          ? [for (final s in _selections) (s.toList()..sort())]
          : null,
      message: !allow && _denyNote.text.trim().isNotEmpty
          ? _denyNote.text.trim()
          : null,
    );
    if (mounted) {
      setState(() => _sending = false);
      // stale_request maps to silence: the desktop answered first and the
      // card is dismissed by the permission_closed already in our state.
      showOutcome(context, outcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.55),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.gpp_maybe_outlined,
                      size: 18, color: scheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      request.toolName,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(request.description),
              if (_ask == null) ...[
                const SizedBox(height: 8),
                _InputPreview(input: request.input),
              ],
              if (_ask != null)
                for (var i = 0; i < _ask!.questions.length; i++)
                  _QuestionCard(
                    question: _ask!.questions[i],
                    selection: _selections[i],
                    onChanged: (selection) =>
                        setState(() => _selections[i] = selection),
                  ),
              if (_showDenyNote)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: _denyNote,
                    decoration: const InputDecoration(
                      labelText: 'Why not? (sent to the agent)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton(
                    onPressed: _sending
                        ? null
                        : () {
                            if (_showDenyNote || _ask != null) {
                              _decide(false);
                            } else {
                              setState(() => _showDenyNote = true);
                            }
                          },
                    child: Text(_showDenyNote ? 'Deny' : 'Deny…'),
                  ),
                  if (_showDenyNote)
                    TextButton(
                      onPressed:
                          _sending ? null : () => _decide(false),
                      child: const Text('Deny without note'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _sending || !_answersComplete
                        ? null
                        : () => _decide(true),
                    child: Text(_ask == null ? 'Allow' : 'Answer'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _denyNote.dispose();
    super.dispose();
  }
}

/// Display-only view of exactly what would execute. Never editable.
class _InputPreview extends StatelessWidget {
  final Object? input;

  const _InputPreview({required this.input});

  @override
  Widget build(BuildContext context) {
    final pretty = const JsonEncoder.withIndent('  ').convert(input);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 160),
      decoration: BoxDecoration(
        color: codeBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: Text(
          pretty,
          style: const TextStyle(fontFamily: codeFontFamily, fontSize: 12),
        ),
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  final AskQuestion question;
  final Set<int> selection;
  final ValueChanged<Set<int>> onChanged;

  const _QuestionCard({
    required this.question,
    required this.selection,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(question.header,
                    style: Theme.of(context).textTheme.labelSmall),
              ),
              if (question.multiSelect)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text('choose any',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: Colors.white38)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(question.question),
          const SizedBox(height: 4),
          for (var i = 0; i < question.options.length; i++)
            _OptionTile(
              option: question.options[i],
              selected: selection.contains(i),
              multiSelect: question.multiSelect,
              onTap: () {
                final next = Set<int>.from(selection);
                if (question.multiSelect) {
                  next.contains(i) ? next.remove(i) : next.add(i);
                } else {
                  next
                    ..clear()
                    ..add(i);
                }
                onChanged(next);
              },
            ),
        ],
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final AskOption option;
  final bool selected;
  final bool multiSelect;
  final VoidCallback onTap;

  const _OptionTile({
    required this.option,
    required this.selected,
    required this.multiSelect,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                multiSelect
                    ? (selected
                        ? Icons.check_box
                        : Icons.check_box_outline_blank)
                    : (selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked),
                size: 18,
                color: selected ? scheme.primary : Colors.white38,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.label),
                    if (option.description.isNotEmpty)
                      Text(option.description,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.white54)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
