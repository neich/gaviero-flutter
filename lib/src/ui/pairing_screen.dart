/// Pairing (QR + a manual token-replacement form). The QR carries the relay
/// fields and the machine CA; manual entry can only replace the token of a
/// machine already paired by QR. The token is never echoed back on screen.
library;

import 'package:flutter/material.dart';

import '../protocol/version.dart';
import '../services/secure_store.dart';
import '../state/controller.dart';
import 'scanner_screen.dart';

class PairingScreen extends StatefulWidget {
  final RemoteController controller;

  /// When set, this is a re-pair for a machine whose token died (4001/4006).
  final String? forMachine;

  const PairingScreen({super.key, required this.controller, this.forMachine});

  @override
  State<PairingScreen> createState() => PairingScreenState();
}

class PairingScreenState extends State<PairingScreen> {
  late final TextEditingController _host;
  final _token = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.forMachine ?? '');
  }

  Future<void> submitPayload(String raw) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final config = parsePairingPayload(raw,
          expectedMajor: protocolVersion.major);
      await widget.controller.pair(config);
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } on PairingError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitManual() async {
    final host = _host.text.trim();
    final token = _token.text.trim();
    if (host.isEmpty || token.isEmpty) {
      setState(() => _error = 'Enter the host and token shown by /remote.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.pairMachineOnly(host, token);
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } on PairingError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rePair = widget.forMachine;
    return Scaffold(
      appBar: AppBar(
        title: Text(rePair == null
            ? 'Pair with gaviero'
            : 'Pair $rePair again'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            rePair == null
                ? 'Run /remote in the gaviero TUI and scan the QR code.'
                : 'The token for $rePair is no longer valid. Scan the QR '
                    'from /remote on that machine.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          buildScannerSection(context),
          const SizedBox(height: 24),
          Text('Replace the token of a paired machine',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'Machine',
              hintText: 'desk.gaviero.example.com',
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

  Widget buildScannerSection(BuildContext context) => FilledButton.icon(
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan QR code'),
        onPressed: _busy
            ? null
            : () async {
                final raw = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                      builder: (context) => const ScannerScreen()),
                );
                if (raw != null) await submitPayload(raw);
              },
      );

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    super.dispose();
  }
}
