/// Instance picker (Plan D D3): home screen. Machines as sections, one row
/// per known instance, pull-to-refresh, tap to connect, long-press to forget.
library;

import 'package:flutter/material.dart';

import '../protocol/version.dart';
import '../services/instance_store.dart';
import '../services/secure_store.dart';
import '../state/controller.dart';
import 'pairing_screen.dart';
import 'scanner_screen.dart';

class InstancePickerScreen extends StatefulWidget {
  final RemoteController controller;

  const InstancePickerScreen({super.key, required this.controller});

  @override
  State<InstancePickerScreen> createState() => _InstancePickerScreenState();
}

class _InstancePickerScreenState extends State<InstancePickerScreen> {
  bool _refreshing = false;

  RemoteController get controller => widget.controller;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await controller.refreshDirectory();
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (context) => const ScannerScreen()),
    );
    if (raw == null || !mounted) return;
    try {
      final config =
          parsePairingPayload(raw, expectedMajor: protocolVersion.major);
      await controller.pair(config);
    } on PairingError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _forgetInstance(InstanceRecord inst) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this instance?'),
        content: Text(inst.displayName),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (confirmed == true) await controller.forgetInstance(inst.key);
  }

  Future<void> _forgetMachine(MachineRecord machine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this machine?'),
        content: Text('Removes ${machine.host} and every instance on it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (confirmed == true) await controller.forgetMachine(machine.host);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final doc = controller.instanceStore.doc;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Instances'),
            actions: [
              IconButton(
                tooltip: 'Pair a machine',
                icon: const Icon(Icons.qr_code_2),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) =>
                      PairingScreen(controller: controller),
                )),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: 'Scan pairing QR',
            onPressed: _scan,
            child: const Icon(Icons.qr_code_scanner),
          ),
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: doc.machines.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 120),
                      Center(child: Text('Pair a machine to get started.')),
                    ],
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      if (_refreshing)
                        const LinearProgressIndicator(minHeight: 2),
                      for (final machine in doc.machines)
                        _MachineSection(
                          machine: machine,
                          instances: [
                            for (final i in doc.instances)
                              if (i.machineHost == machine.host) i
                          ],
                          store: controller.instanceStore,
                          onTap: (inst) => controller.connect(inst),
                          onForgetInstance: _forgetInstance,
                          onForgetMachine: () => _forgetMachine(machine),
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _MachineSection extends StatelessWidget {
  final MachineRecord machine;
  final List<InstanceRecord> instances;
  final InstanceStore store;
  final void Function(InstanceRecord inst) onTap;
  final void Function(InstanceRecord inst) onForgetInstance;
  final VoidCallback onForgetMachine;

  const _MachineSection({
    required this.machine,
    required this.instances,
    required this.store,
    required this.onTap,
    required this.onForgetInstance,
    required this.onForgetMachine,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(machine.host,
              style: Theme.of(context).textTheme.titleSmall),
          trailing: PopupMenuButton<String>(
            onSelected: (choice) {
              if (choice == 'forget') onForgetMachine();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'forget', child: Text('Forget machine')),
            ],
          ),
        ),
        for (final inst in instances)
          _InstanceRow(
            inst: inst,
            chip: store.chipFor(inst),
            onTap: () => onTap(inst),
            onLongPress: () => onForgetInstance(inst),
          ),
        if (instances.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text('No instances yet — pull to refresh, or scan a QR.'),
          ),
      ],
    );
  }
}

class _InstanceRow extends StatelessWidget {
  final InstanceRecord inst;
  final InstanceChip chip;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _InstanceRow({
    required this.inst,
    required this.chip,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final hostPort = '${inst.machineHost}:${inst.port}';
    return ListTile(
      key: ValueKey('instance-${inst.machineHost}-${inst.workspaceId ?? inst.url}'),
      title: Text(inst.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hostPort),
          if (inst.lastSeen != null)
            Text('Last seen ${inst.lastSeen}',
                style: Theme.of(context).textTheme.labelSmall),
          if (chip == InstanceChip.inUse)
            Text('another device is connected — connecting will replace it',
                style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
      trailing: _Chip(chip: chip),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

class _Chip extends StatelessWidget {
  final InstanceChip chip;
  const _Chip({required this.chip});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (chip) {
      InstanceChip.online => ('online', Colors.green),
      InstanceChip.inUse => ('in use', Colors.orange),
      InstanceChip.offline => ('offline', Colors.grey),
      InstanceChip.unknown => ('unknown', Colors.blueGrey),
      InstanceChip.needsPairing => ('needs pairing', Colors.redAccent),
    };
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color.withValues(alpha: 0.6)),
    );
  }
}
