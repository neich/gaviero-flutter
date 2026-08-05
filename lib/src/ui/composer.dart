/// Prompt composer (minimal B4 form: plain prompt send + interrupt). B8
/// adds slash chips, confirm gating, and allow-list-driven commands.
library;

import 'package:flutter/material.dart';

import '../state/controller.dart';

class Composer extends StatefulWidget {
  final RemoteController controller;

  const Composer({super.key, required this.controller});

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    await widget.controller.sendPrompt(text);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final streaming = controller.state.active?.summary.isStreaming ?? false;
    final connected = controller.connection.isConnected;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                enabled: connected,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: connected ? 'Message the agent…' : 'Offline',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (streaming)
              IconButton.filledTonal(
                tooltip: 'Interrupt',
                onPressed: connected ? controller.interrupt : null,
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
    );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}
