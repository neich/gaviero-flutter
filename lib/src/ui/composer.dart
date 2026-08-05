/// Composer + slash chips (B8). The entire command surface is built from
/// `hello.allowed_slash_commands` — hard-coding a list is a bug: it would
/// show commands the server rejects and hide ones it gains. Commands in
/// `hello.confirm_required` raise a dialog and send `confirmed: true`.
/// A `slash_not_allowed` reply renders as a calm inline notice — it is
/// policy, not a failure.
library;

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

  RemoteController get controller => widget.controller;

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
          if (connected && allowed.isNotEmpty)
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
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }
}
