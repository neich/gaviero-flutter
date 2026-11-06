/// Composer + slash chips (B8). The entire command surface is built from
/// `hello.allowed_slash_commands` — hard-coding a list is a bug: it would
/// show commands the server rejects and hide ones it gains. Commands in
/// `hello.confirm_required` raise a dialog and send `confirmed: true`.
/// A `slash_not_allowed` reply renders as a calm inline notice — it is
/// policy, not a failure. Typing `@` asks the desktop for workspace paths
/// (`file_completions`) and offers them above the input; typing `$skill`
/// asks for catalog skills (`skill_completions`) the same way. While the viewed
/// conversation has a pending turn review (`turn_review`) prompts are held:
/// Send is disabled for anything but a slash line, with a hint.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import 'feedback.dart';

/// Commands known to take an argument: their chips prefill the composer
/// instead of sending. A command the server adds later that we do not know
/// defaults to prefill — the safe option.
const _argumentCommands = {
  '/model', '/effort', '/thinking', '/rename',
  '/namespace', '/ns', '/workspace', '/ws',
};

const _directCommands = {
  '/compact', '/context', '/inject', '/no-inject', '/reset', '/clear',
  '/autoapprove', '/yolo', '/lite', '/minimal', '/help', '/skills',
};

/// Quiet time after a keystroke before asking the desktop for `@` paths;
/// keeps typing well under `hello.limits.command_rate_per_second`.
const _completionDebounce = Duration(milliseconds: 150);

final _whitespace = RegExp(r'\s');

/// The `@path` token the caret sits in, or null. Same rule as the desktop
/// popup: the `@` starts the text or follows whitespace, and no whitespace
/// lies between it and the caret. Slash lines never complete. Offsets are
/// UTF-16 code units, as [TextSelection] reports them.
@visibleForTesting
({int start, String query})? fileReferenceAt(String text, int caret) =>
    _referenceAt('@', text, caret);

/// The `$skill` token the caret sits in, or null. Same rule as the desktop
/// popup: the `$` starts the text or follows whitespace (an escaped `\$` is
/// literal), no whitespace lies between it and the caret, and at least two
/// characters are typed — so `$5` or a lone `$` never asks.
@visibleForTesting
({int start, String query})? skillReferenceAt(String text, int caret) {
  final reference = _referenceAt(r'$', text, caret);
  return reference != null && reference.query.length >= 2 ? reference : null;
}

({int start, String query})? _referenceAt(
    String sigil, String text, int caret) {
  if (caret < 0 || caret > text.length || text.trimLeft().startsWith('/')) {
    return null;
  }
  final before = text.substring(0, caret);
  final at = before.lastIndexOf(sigil);
  if (at < 0) return null;
  if (at > 0 && !_whitespace.hasMatch(before[at - 1])) return null;
  final query = before.substring(at + 1);
  if (_whitespace.hasMatch(query)) return null;
  return (start: at, query: query);
}

enum _CompletionKind { file, skill }

typedef _Token = ({_CompletionKind kind, int start, String query});

/// One `$` match from `request_skill_completions`.
typedef _SkillMatch = ({String insert, String description});

class Composer extends StatefulWidget {
  final RemoteController controller;

  const Composer({super.key, required this.controller});

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  String? _inlineNotice;

  Timer? _completionTimer;
  bool _completionInFlight = false;

  /// The token [_files] / [_skills] answer; null when nothing is showing.
  ({_CompletionKind kind, String query})? _shown;
  List<String> _files = const [];
  List<_SkillMatch> _skills = const [];

  RemoteController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
  }

  /// The viewed conversation's last turn changed files and its review is not
  /// finalized: the server refuses `send_prompt` (slash commands still go).
  bool get _turnReviewPending {
    final convId = controller.state.viewedId;
    return convId != null &&
        controller.supportsTurnReview &&
        controller.state.hasPendingTurnReview(convId);
  }

  bool _supports(String capability) =>
      controller.connection.hello?.hasCapability(capability) ?? false;

  /// The completable token under the caret. A `$skill` token wins over `@`,
  /// as on the desktop; each kind only on a server advertising it.
  _Token? get _token {
    final selection = _text.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final text = _text.text;
    final caret = selection.baseOffset;
    if (_supports(Capability.skillCompletions)) {
      final skill = skillReferenceAt(text, caret);
      if (skill != null) {
        return (kind: _CompletionKind.skill, start: skill.start,
            query: skill.query);
      }
    }
    if (_supports(Capability.fileCompletions)) {
      final file = fileReferenceAt(text, caret);
      if (file != null) {
        return (kind: _CompletionKind.file, start: file.start,
            query: file.query);
      }
    }
    return null;
  }

  static bool _sameToken(_Token? token, ({_CompletionKind kind, String query})? shown) =>
      token != null &&
      shown != null &&
      token.kind == shown.kind &&
      token.query == shown.query;

  void _clearSuggestions() {
    _shown = null;
    _files = const [];
    _skills = const [];
  }

  void _onTextChanged() {
    final token = _token;
    if (token == null) {
      _completionTimer?.cancel();
      if (_shown != null) setState(_clearSuggestions);
      return;
    }
    if (_sameToken(token, _shown)) return;
    _completionTimer?.cancel();
    _completionTimer = Timer(_completionDebounce, _fetchCompletions);
  }

  /// One request in flight at a time. When it lands the caret is re-read:
  /// a reply for a token the user has typed past is dropped and the current
  /// token fetched instead.
  Future<void> _fetchCompletions() async {
    final token = _token;
    if (_completionInFlight || token == null || !mounted) return;
    _completionInFlight = true;
    final outcome = switch (token.kind) {
      _CompletionKind.file => await controller.requestFileCompletions(token.query),
      _CompletionKind.skill =>
        await controller.requestSkillCompletions(token.query),
    };
    _completionInFlight = false;
    if (!mounted) return;
    final current = _token;
    if (current == null) return;
    if (current.kind != token.kind || current.query != token.query) {
      unawaited(_fetchCompletions());
      return;
    }
    // A failed request (e.g. rate_limited) clears the list instead of leaving
    // an older query's matches up; the next keystroke asks again.
    final result = switch (outcome) {
      CommandOk(result: CommandResult(result: final Map<String, Object?> r)) =>
        r,
      _ => null,
    };
    setState(() {
      _clearSuggestions();
      switch ((token.kind, result)) {
        case (_CompletionKind.file, {'files': final List<Object?> files}):
          _files = [
            for (final file in files)
              if (file is String) file
          ];
        case (_CompletionKind.skill, {'skills': final List<Object?> skills}):
          _skills = [
            for (final skill in skills)
              if (skill case {'insert': final String insert})
                (
                  insert: insert,
                  description: switch (skill) {
                    {'description': final String d} => d,
                    _ => '',
                  },
                )
          ];
        default:
          return;
      }
      _shown = (kind: token.kind, query: token.query);
    });
  }

  /// Replaces the whole token — including any part right of the caret —
  /// with [replacement] and one separating space.
  void _acceptSuggestion(String replacement) {
    final token = _token;
    if (token == null) return;
    final text = _text.text;
    var end = _text.selection.baseOffset;
    while (end < text.length && !_whitespace.hasMatch(text[end])) {
      end++;
    }
    final tail = text.substring(end);
    final spaced = tail.isNotEmpty && _whitespace.hasMatch(tail[0]);
    final inserted = spaced ? replacement : '$replacement ';
    _completionTimer?.cancel();
    _text.value = TextEditingValue(
      text: text.substring(0, token.start) + inserted + tail,
      selection: TextSelection.collapsed(
          offset: token.start + inserted.length + (spaced ? 1 : 0)),
    );
    _focus.requestFocus();
  }

  Future<bool> _confirm(String command) async {
    // Clearing the chat does not decide its turn review: the next prompt
    // stays held, so say so before the user expects a fresh start.
    final reviewNote = _turnReviewPending
        ? ' The pending turn review stays open — the next prompt is still '
            'held until every file is accepted or rejected.'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Send $command?'),
        content: Text(switch (command) {
          '/reset' || '/clear' =>
            'This clears the conversation on the desktop as well.$reviewNote',
          '/autoapprove' || '/yolo' =>
            'The agent will act without asking for approval — on the '
                'desktop too.',
          _ => 'The desktop requires confirmation for this command.',
        }),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Send $command')),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _sendSlashLine(String line) async {
    final command = line.split(RegExp(r'\s+')).first;
    final confirmRequired =
        controller.connection.hello?.confirmRequired.contains(command) ??
            false;
    if (confirmRequired && !await _confirm(command)) return;
    final outcome =
        await controller.sendSlash(line, confirmed: confirmRequired);
    if (!mounted) return;
    if (outcome case CommandFail(:final error)
        when error.code == ErrorCode.slashNotAllowed) {
      setState(() => _inlineNotice =
          '$command isn\'t available from the phone — it stays a '
          'desktop-only command.');
      return;
    }
    showOutcome(context, outcome);
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    if (text.startsWith('/')) {
      _text.clear();
      await _sendSlashLine(text);
      return;
    }
    if (_turnReviewPending) return; // Send is disabled; the hint explains.
    final maxBytes = controller.connection.hello?.limits.maxPromptBytes;
    if (maxBytes != null && utf8.encode(text).length > maxBytes) {
      setState(() => _inlineNotice =
          'That prompt is over the ${maxBytes ~/ 1024} KiB limit — trim it '
          'or send it from the desktop.');
      return;
    }
    _text.clear();
    final outcome = await controller.sendPrompt(text);
    if (mounted) showOutcome(context, outcome);
  }

  void _onChipTap(String command) {
    if (_argumentCommands.contains(command) ||
        !_directCommands.contains(command)) {
      // Argument-taking (and unknown) commands prefill rather than send.
      _text.text = '$command ';
      _text.selection =
          TextSelection.collapsed(offset: _text.text.length);
      _focus.requestFocus();
    } else {
      _sendSlashLine(command);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The Stop/Send swap belongs to the conversation this composer prompts or
    // interrupts (`viewed`), not to the desktop-active tab: a turn running in
    // another tab must not turn this one's send button into a Stop button.
    final streaming = controller.state.viewed?.summary.isStreaming ?? false;
    final connected = controller.connection.isConnected;
    final allowed =
        controller.connection.hello?.allowedSlashCommands ?? const [];
    final suggestingFiles = connected && _files.isNotEmpty;
    final suggestingSkills = connected && _skills.isNotEmpty;
    final reviewPending = _turnReviewPending;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reviewPending)
            Padding(
              key: const Key('turn-review-send-hint'),
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: Row(
                children: [
                  Icon(Icons.fact_check_outlined,
                      size: 15,
                      color: Theme.of(context).colorScheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Accept or reject the changed files above to send the '
                      'next prompt.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (_inlineNotice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 6, 0),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 15,
                      color: Theme.of(context).colorScheme.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_inlineNotice!,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 15),
                    onPressed: () => setState(() => _inlineNotice = null),
                  ),
                ],
              ),
            ),
          if (suggestingSkills)
            _SkillSuggestions(skills: _skills, onSelected: _acceptSuggestion)
          else if (suggestingFiles)
            _FileSuggestions(
                paths: _files,
                onSelected: (path) => _acceptSuggestion('@$path'))
          else if (connected && allowed.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  for (final command in allowed)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        label: Text(command),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _onChipTap(command),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    enabled: connected,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: !connected
                          ? 'Offline'
                          : reviewPending
                              ? 'Review pending — slash commands only'
                              : 'Message the agent…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (streaming)
                  IconButton.filledTonal(
                    tooltip: 'Interrupt',
                    onPressed: connected
                        ? () async {
                            final outcome = await controller.interrupt();
                            if (context.mounted) {
                              showOutcome(context, outcome);
                            }
                          }
                        : null,
                    icon: const Icon(Icons.stop),
                  )
                else
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _text,
                    builder: (context, value, _) => IconButton.filled(
                      tooltip: 'Send',
                      // A pending turn review holds prompts, not slash lines.
                      onPressed: connected &&
                              (!reviewPending ||
                                  value.text.trimLeft().startsWith('/'))
                          ? _send
                          : null,
                      icon: const Icon(Icons.arrow_upward),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _completionTimer?.cancel();
    _text.removeListener(_onTextChanged);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }
}

/// `$` matches, shown in place of the slash chips: the text a tap inserts
/// (`$name`, `$label/name` for a name two scopes share, `()` when the skill
/// takes arguments) with its description underneath.
class _SkillSuggestions extends StatelessWidget {
  final List<_SkillMatch> skills;
  final ValueChanged<String> onSelected;

  const _SkillSuggestions({required this.skills, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      child: Material(
        key: const Key('skill-suggestions'),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: skills.length,
            itemBuilder: (context, index) {
              final skill = skills[index];
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.auto_awesome_outlined, size: 18),
                title: Text(skill.insert,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: skill.description.isEmpty
                    ? null
                    : Text(skill.description,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () => onSelected(skill.insert),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// `@` matches, shown in place of the slash chips: file name first, its
/// folder underneath, so a long path still shows what it points at.
class _FileSuggestions extends StatelessWidget {
  final List<String> paths;
  final ValueChanged<String> onSelected;

  const _FileSuggestions({required this.paths, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      child: Material(
        key: const Key('file-suggestions'),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: paths.length,
            itemBuilder: (context, index) {
              final path = paths[index];
              final slash = path.lastIndexOf('/');
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading:
                    const Icon(Icons.insert_drive_file_outlined, size: 18),
                title: Text(path.substring(slash + 1),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: slash < 0
                    ? null
                    : Text(path.substring(0, slash),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => onSelected(path),
              );
            },
          ),
        ),
      ),
    );
  }
}
