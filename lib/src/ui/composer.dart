/// Composer + slash chips (B8). The entire command surface is built from
/// `hello.allowed_slash_commands` — hard-coding a list is a bug: it would
/// show commands the server rejects and hide ones it gains. Commands in
/// `hello.confirm_required` raise a dialog and send `confirmed: true`.
/// A `slash_not_allowed` reply renders as a calm inline notice — it is
/// policy, not a failure. Typing `@` asks the desktop for workspace paths
/// (`file_completions`) and offers them above the input.
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
({int start, String query})? fileReferenceAt(String text, int caret) {
  if (caret < 0 || caret > text.length || text.trimLeft().startsWith('/')) {
    return null;
  }
  final before = text.substring(0, caret);
  final at = before.lastIndexOf('@');
  if (at < 0) return null;
  if (at > 0 && !_whitespace.hasMatch(before[at - 1])) return null;
  final query = before.substring(at + 1);
  if (_whitespace.hasMatch(query)) return null;
  return (start: at, query: query);
}

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

  /// The query [_suggestions] answer; null when nothing is showing.
  String? _suggestionsQuery;
  List<String> _suggestions = const [];

  RemoteController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
  }

  bool get _completionsSupported =>
      controller.connection.hello
          ?.hasCapability(Capability.fileCompletions) ??
      false;

  ({int start, String query})? get _reference {
    final selection = _text.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    return fileReferenceAt(_text.text, selection.baseOffset);
  }

  void _onTextChanged() {
    final reference = _completionsSupported ? _reference : null;
    if (reference == null) {
      _completionTimer?.cancel();
      if (_suggestionsQuery != null) {
        setState(() {
          _suggestionsQuery = null;
          _suggestions = const [];
        });
      }
      return;
    }
    if (reference.query == _suggestionsQuery) return;
    _completionTimer?.cancel();
    _completionTimer = Timer(_completionDebounce, _fetchCompletions);
  }

  /// One request in flight at a time. When it lands the caret is re-read:
  /// a reply for a query the user has typed past is dropped and the current
  /// query fetched instead.
  Future<void> _fetchCompletions() async {
    final reference = _reference;
    if (_completionInFlight || reference == null || !mounted) return;
    _completionInFlight = true;
    final outcome = await controller.requestFileCompletions(reference.query);
    _completionInFlight = false;
    if (!mounted) return;
    final current = _reference;
    if (current == null) return;
    if (current.query != reference.query) {
      unawaited(_fetchCompletions());
      return;
    }
    // A failed request (e.g. rate_limited) clears the list instead of leaving
    // an older query's matches up; the next keystroke asks again.
    final files = switch (outcome) {
      CommandOk(
        result: CommandResult(result: {'files': final List<Object?> files})
      ) =>
        [
          for (final file in files)
            if (file is String) file
        ],
      _ => null,
    };
    setState(() {
      _suggestionsQuery = files == null ? null : reference.query;
      _suggestions = files ?? const [];
    });
  }

  /// Replaces the whole `@` token — including any part right of the caret —
  /// with `@<path>` and one separating space.
  void _acceptSuggestion(String path) {
    final reference = _reference;
    if (reference == null) return;
    final text = _text.text;
    var end = _text.selection.baseOffset;
    while (end < text.length && !_whitespace.hasMatch(text[end])) {
      end++;
    }
    final tail = text.substring(end);
    final spaced = tail.isNotEmpty && _whitespace.hasMatch(tail[0]);
    final replacement = spaced ? '@$path' : '@$path ';
    _completionTimer?.cancel();
    _text.value = TextEditingValue(
      text: text.substring(0, reference.start) + replacement + tail,
      selection: TextSelection.collapsed(
          offset: reference.start + replacement.length + (spaced ? 1 : 0)),
    );
    _focus.requestFocus();
  }

  Future<bool> _confirm(String command) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Send $command?'),
        content: Text(switch (command) {
          '/reset' || '/clear' =>
            'This clears the conversation on the desktop as well.',
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
    final streaming = controller.state.active?.summary.isStreaming ?? false;
    final connected = controller.connection.isConnected;
    final allowed =
        controller.connection.hello?.allowedSlashCommands ?? const [];
    final suggesting = connected && _suggestions.isNotEmpty;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
          if (suggesting)
            _FileSuggestions(paths: _suggestions, onSelected: _acceptSuggestion)
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
                      hintText:
                          connected ? 'Message the agent…' : 'Offline',
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
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: connected ? _send : null,
                    icon: const Icon(Icons.arrow_upward),
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
