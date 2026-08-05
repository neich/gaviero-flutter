/// Pairing (manual-entry form; the QR scanner arrives in B9). Host + token
/// go straight into secure storage; the token is never echoed back on
/// screen after saving.
library;

import 'package:flutter/material.dart';

import '../protocol/version.dart';
import '../services/secure_store.dart';
import '../state/controller.dart';

class PairingScreen extends StatefulWidget {
  final RemoteController controller;

  const PairingScreen({super.key, required this.controller});

  @override
  State<PairingScreen> createState() => PairingScreenState();
}

class PairingScreenState extends State<PairingScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> submitPayload(String raw) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final config = parsePairingPayload(raw,
          expectedMajor: protocolVersion.major);
      await widget.controller.pair(config);
    } on PairingError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitManual() async {
    final url = _url.text.trim();
    final token = _token.text.trim();
    if (!url.startsWith('wss://') || token.isEmpty) {
      setState(() =>
          _error = 'Enter the wss:// URL and token shown by /remote.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.controller
        .pair(PairingConfig(url: url, token: token, workspace: ''));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair with gaviero')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Run /remote in the gaviero TUI and scan the QR code, or enter '
            'the connection details manually.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          buildScannerSection(context),
          const SizedBox(height: 24),
          Text('Manual entry',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'WebSocket URL',
              hintText: 'wss://host.tailnet.ts.net:PORT/v1/ws',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Token',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submitManual,
            child: const Text('Connect'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }

  /// Overridden by the B9 scanner build; the base form is camera-free.
  Widget buildScannerSection(BuildContext context) =>
      const SizedBox.shrink();

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }
}
