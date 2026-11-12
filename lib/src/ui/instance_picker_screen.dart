/// Instance picker. One list mixing every paired machine's instances, most
/// recently used first, each row naming its machine; offline rows are
/// greyed and removable. A Machines section below holds the per-machine
/// actions (remove offline instances, forget machine). Pull-to-refresh, tap
/// to connect, long-press to forget. Opened from any section's bar it
/// covers the current instance, which stays connected and is marked here;
/// Back returns to it unchanged.
library;

import 'package:flutter/material.dart';

import '../protocol/version.dart';
import '../services/instance_store.dart';
import '../services/secure_store.dart';
import '../state/hub.dart';
import 'pairing_screen.dart';
import 'scanner_screen.dart';

/// Picker order across all machines: the current instance first, then
/// instances this device has opened, most recently used first, then the
/// never-opened ones by status (in use, reachable, offline). Stable, so
/// store order breaks the remaining ties.
List<InstanceRecord> orderForPicker(
  List<InstanceRecord> instances,
  InstanceStore store,
  InstanceKey? currentKey,
) {
  int rank(InstanceRecord inst) => switch (store.chipFor(inst)) {
        InstanceChip.inUse => 0,
        InstanceChip.online ||
        InstanceChip.unknown ||
        InstanceChip.needsPairing => 1,
        InstanceChip.offline => 2,
      };

  int compare(InstanceRecord a, InstanceRecord b) {
    final aCurrent = a.key == currentKey, bCurrent = b.key == currentKey;
    if (aCurrent != bCurrent) return aCurrent ? -1 : 1;
    final aUsed = a.lastUsedAt, bUsed = b.lastUsedAt;
    if (aUsed != null && bUsed != null) return bUsed.compareTo(aUsed);
    if (aUsed != null) return -1;
    if (bUsed != null) return 1;
    return rank(a).compareTo(rank(b));
  }

  final indexed = [for (var i = 0; i < instances.length; i++) (i, instances[i])];
  indexed.sort((a, b) {
    final byOrder = compare(a.$2, b.$2);
    return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
  });
  return [for (final (_, inst) in indexed) inst];
}

class InstancePickerScreen extends StatefulWidget {
  final RemoteHub controller;

  const InstancePickerScreen({super.key, required this.controller});

  @override
  State<InstancePickerScreen> createState() => _InstancePickerScreenState();
}

class _InstancePickerScreenState extends State<InstancePickerScreen> {
  bool _refreshing = false;

  RemoteHub get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

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
      final config = parsePairingPayload(
        raw,
        expectedMajor: protocolVersion.major,
      );
      await controller.pair(config);
    } on PairingError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _forgetInstance(InstanceRecord inst) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this instance from the list?'),
        content: Text(inst.displayName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.forgetInstance(inst.key);
  }

  Future<void> _removeOffline(
    MachineRecord machine,
    List<InstanceRecord> offline,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove offline instances?'),
        content: Text(
          'Removes ${offline.length} offline instance'
          '${offline.length == 1 ? '' : 's'} on ${machine.host} from the list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final inst in offline) {
      await controller.forgetInstance(inst.key);
    }
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.forgetMachine(machine.host);
  }

  Widget _buildList(
    BuildContext context,
    StoreDocument doc,
    InstanceKey? currentKey,
  ) {
    final store = controller.instanceStore;
    bool isOffline(InstanceRecord inst) =>
        inst.key != currentKey && store.chipFor(inst) == InstanceChip.offline;
    final ordered = orderForPicker(doc.instances, store, currentKey);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (_refreshing) const LinearProgressIndicator(minHeight: 2),
        for (final inst in ordered)
          _InstanceRow(
            inst: inst,
            chip: store.chipFor(inst),
            isCurrent: inst.key == currentKey,
            isOffline: isOffline(inst),
            onTap: () => controller.connect(inst),
            onLongPress: () => _forgetInstance(inst),
            onRemove: () => _forgetInstance(inst),
          ),
        if (ordered.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Text('No instances yet — pull to refresh, or scan a QR.'),
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Machines',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final machine in doc.machines)
          _MachineTile(
            machine: machine,
            instanceCount: doc.instances
                .where((i) => i.machineHost == machine.host)
                .length,
            offline: [
              for (final i in doc.instances)
                if (i.machineHost == machine.host && isOffline(i)) i,
            ],
            onForgetMachine: () => _forgetMachine(machine),
            onRemoveOffline: (offline) => _removeOffline(machine, offline),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final doc = controller.instanceStore.doc;
        final hasCurrent = controller.session != null;
        final currentKey = controller.current?.key;
        return PopScope(
          // With an instance behind the picker, Back returns to it.
          canPop: !hasCurrent,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) controller.hideInstances();
          },
          child: Scaffold(
          appBar: AppBar(
            leading: hasCurrent
                ? BackButton(
                    key: const Key('instances-back'),
                    onPressed: controller.hideInstances,
                  )
                : null,
            title: const Text('Instances'),
            actions: [
              IconButton(
                tooltip: 'Pair a machine',
                icon: const Icon(Icons.qr_code_2),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => PairingScreen(controller: controller),
                  ),
                ),
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
                : _buildList(context, doc, currentKey),
          ),
          ),
        );
      },
    );
  }
}

/// One paired machine in the Machines section, with its actions menu.
class _MachineTile extends StatelessWidget {
  final MachineRecord machine;
  final int instanceCount;

  /// This machine's offline instances (never the current one).
  final List<InstanceRecord> offline;
  final VoidCallback onForgetMachine;
  final void Function(List<InstanceRecord> offline) onRemoveOffline;

  const _MachineTile({
    required this.machine,
    required this.instanceCount,
    required this.offline,
    required this.onForgetMachine,
    required this.onRemoveOffline,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('machine-${machine.host}'),
      leading: const Icon(Icons.computer),
      title: Text(machine.host),
      subtitle: Text(
        '$instanceCount instance${instanceCount == 1 ? '' : 's'}',
      ),
      trailing: PopupMenuButton<String>(
        key: ValueKey('machine-menu-${machine.host}'),
        onSelected: (choice) {
          if (choice == 'forget') onForgetMachine();
          if (choice == 'remove-offline') onRemoveOffline(offline);
        },
        itemBuilder: (context) => [
          if (offline.isNotEmpty)
            const PopupMenuItem(
              value: 'remove-offline',
              child: Text('Remove offline instances'),
            ),
          const PopupMenuItem(
            value: 'forget',
            child: Text('Forget machine'),
          ),
        ],
      ),
    );
  }
}

class _InstanceRow extends StatelessWidget {
  final InstanceRecord inst;
  final InstanceChip chip;
  final bool isCurrent;

  /// Offline and not the current instance: greyed, with a remove button.
  final bool isOffline;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;

  const _InstanceRow({
    required this.inst,
    required this.chip,
    required this.isCurrent,
    required this.isOffline,
    required this.onTap,
    required this.onLongPress,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final id = '${inst.machineHost}-${inst.workspaceId ?? inst.url}';
    final grey = isOffline ? Theme.of(context).disabledColor : null;
    return ListTile(
      key: ValueKey('instance-$id'),
      selected: isCurrent,
      textColor: grey,
      iconColor: grey,
      title: Text(inst.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Rows from every machine share one list, so each names its own.
          Row(
            key: ValueKey('instance-machine-$id'),
            children: [
              const Icon(Icons.computer, size: 14),
              const SizedBox(width: 4),
              Flexible(
                child: Text(inst.machineHost, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          if (inst.lastSeen != null)
            Text(
              'Last seen ${inst.lastSeen}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (isCurrent)
            Text(
              'current instance',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (chip == InstanceChip.inUse && !isCurrent)
            Text(
              'another device is connected — connecting will replace it',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
      trailing: isOffline
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Chip(chip: chip),
                IconButton(
                  key: ValueKey('remove-$id'),
                  tooltip: 'Remove from list',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onRemove,
                ),
              ],
            )
          : _Chip(chip: chip),
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
      labelStyle: chip == InstanceChip.offline
          ? TextStyle(color: Theme.of(context).disabledColor)
          : null,
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color.withValues(alpha: 0.6)),
    );
  }
}
