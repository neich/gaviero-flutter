/// Approvals (B6). A permission decision cannot change what executes: the
/// displayed `input` is read-only, answers travel as option indices
/// (`answers: [[i]]`), never a rebuilt tool-input document, and the server
/// reconstructs the input itself. A request answered on the desktop first
/// (`permission_closed` / `stale_request`) dismisses without an error —
/// losing that race is normal.
///
/// A plain request offers every answer the desktop overlay does, labelled
/// with its key: `y` Allow, `n` Deny, `a` Allow for session, `A` all tools of
/// the MCP server, `p` Allow all until the next prompt (protocol 1.6
/// `grants`); those keys also work from a hardware keyboard.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

class _PermissionCardState extends State<PermissionCard>
    with AutomaticKeepAliveClientMixin {
  late List<Set<int>> _selections;

  // The card is a row of the chat's message list; scrolling up to read the
  // explanation or an earlier question must not drop the picked answers.
  @override
  bool get wantKeepAlive => true;
  bool _sending = false;
  bool _showDenyNote = false;
  final _denyNote = TextEditingController();

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

  /// Standing answers offered beside Allow / Deny, in the desktop overlay's
  /// order. A 1.6 server lists them per request (`grants`) and the card shows
  /// exactly those; a 1.4/1.5 server only knows `mcp_server_turn`, offered
  /// when the request names its `mcp_server`. Never on a question.
  List<PermissionGrant> get _grants {
    if (_ask != null) return const [];
    final controller = widget.controller;
    if (controller.supportsPermissionGrants) return widget.request.grants;
    if (controller.supportsPermissionTurnGrant &&
        widget.request.mcpServer != null) {
      return const [PermissionGrant.mcpServerTurn];
    }
    return const [];
  }

  /// MCP server named by the server-wide grants: the request's `mcp_server`,
  /// else the `<server>` of an `mcp__<server>__<tool>` name.
  String get _server {
    if (widget.request.mcpServer case final server?) return server;
    final parts = widget.request.toolName.split('__');
    return parts.length >= 3 && parts.first == 'mcp' ? parts[1] : 'MCP';
  }

  /// Hardware keyboard: the desktop overlay's keys (y / n / a / A / p) work
  /// while no text field has focus. Unoffered keys do nothing, as there.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || _sending || _ask != null) return false;
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    if (focused is EditableText) return false;
    final grants = _grants;
    switch (event.character) {
      case 'y' || 'Y':
        _decide(true);
      case 'n' || 'N':
        _decide(false);
      case final key? when _grantFor(key, grants) != null:
        _decide(true, grant: _grantFor(key, grants));
      default:
        return false;
    }
    return true;
  }

  static PermissionGrant? _grantFor(String key, List<PermissionGrant> offered) {
    for (final grant in offered) {
      if (_grantKey(grant) == key) return grant;
    }
    return null;
  }

  /// The desktop key for [grant]; `mcp_server_turn` has none there.
  static String? _grantKey(PermissionGrant grant) => switch (grant) {
        PermissionGrant.toolSession => 'a',
        PermissionGrant.mcpServerSession => 'A',
        PermissionGrant.mcpServerTurn => null,
        PermissionGrant.turnAll => 'p',
      };

  (String, String) _grantText(PermissionGrant grant) => switch (grant) {
        PermissionGrant.toolSession => (
            'Allow for session',
            '${widget.request.toolName} stops asking in this conversation',
          ),
        PermissionGrant.mcpServerSession => (
            'All $_server tools',
            'Every $_server tool stops asking in this conversation',
          ),
        PermissionGrant.mcpServerTurn => (
            'All $_server tools (this prompt)',
            'Every $_server tool, until your next prompt',
          ),
        PermissionGrant.turnAll => (
            'Allow all (this prompt)',
            'Every request until your next prompt — shell commands '
                'included; questions and network asks still ask',
          ),
      };

  @override
  void initState() {
    super.initState();
    _initSelections();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  Future<void> _decide(bool allow, {PermissionGrant? grant}) async {
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
      grant: grant,
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
    super.build(context);
    final request = widget.request;
    final scheme = Theme.of(context).colorScheme;
    // No scroll view of its own: the chat's message list scrolls the card
    // together with the reply that led to it.
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
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
              // The desktop overlay's standing answers, in its order.
              for (final grant in _grants) ...[
                const SizedBox(height: 8),
                _GrantButton(
                  key: ValueKey('grant-${grant.wire}'),
                  keyLabel: _grantKey(grant),
                  title: _grantText(grant).$1,
                  subtitle: _grantText(grant).$2,
                  onPressed:
                      _sending ? null : () => _decide(true, grant: grant),
                ),
              ],
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
                    child: _Keyed(
                      keyLabel: 'n',
                      text: _showDenyNote ? 'Deny' : 'Deny…',
                    ),
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
                    child: _ask == null
                        ? const _Keyed(keyLabel: 'y', text: 'Allow')
                        : const Text('Answer'),
                  ),
                ],
              ),
            ],
          ),
      ),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _denyNote.dispose();
    super.dispose();
  }
}

/// A desktop key shown as a small badge, as the TUI's `[p]` hints.
class _KeyBadge extends StatelessWidget {
  final String label;

  const _KeyBadge(this.label);

  @override
  Widget build(BuildContext context) {
    final color = DefaultTextStyle.of(context).style.color ?? Colors.white70;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(fontFamily: codeFontFamily, fontSize: 11),
      ),
    );
  }
}

/// Button content: the desktop key badge, then [text].
class _Keyed extends StatelessWidget {
  final String keyLabel;
  final String text;

  const _Keyed({required this.keyLabel, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _KeyBadge(keyLabel),
        const SizedBox(width: 6),
        Text(text),
      ],
    );
  }
}

/// One standing answer: full-width, key badge, title and what it covers.
class _GrantButton extends StatelessWidget {
  final String? keyLabel;
  final String title;
  final String subtitle;
  final VoidCallback? onPressed;

  const _GrantButton({
    super.key,
    required this.keyLabel,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        child: Row(
          children: [
            if (keyLabel case final key?)
              _KeyBadge(key)
            else
              const Icon(Icons.done_all, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  Text(
                    subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
