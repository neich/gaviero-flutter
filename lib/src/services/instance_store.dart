/// Machine + instance pairing document (Plan D §3.1). One JSON string under
/// `instances_v2`. Legacy Plan B keys are migrated once, then deleted.
library;

import 'dart:convert';

import 'kv.dart';

const instancesV2Key = 'instances_v2';
const legacyUrlKey = 'pairing_url';
const legacyTokenKey = 'pairing_token';
const legacyWorkspaceKey = 'pairing_workspace';

final class MachineRecord {
  final String host;
  final String token;
  final String? directoryUrl;
  final String pairedAt;

  /// Token is dead (401 / 4001 / 4006); user must pair again.
  final bool needsPairing;

  const MachineRecord({
    required this.host,
    required this.token,
    this.directoryUrl,
    required this.pairedAt,
    this.needsPairing = false,
  });

  MachineRecord copyWith({
    String? token,
    String? directoryUrl,
    String? pairedAt,
    bool? needsPairing,
  }) =>
      MachineRecord(
        host: host,
        token: token ?? this.token,
        directoryUrl: directoryUrl ?? this.directoryUrl,
        pairedAt: pairedAt ?? this.pairedAt,
        needsPairing: needsPairing ?? this.needsPairing,
      );

  Map<String, Object?> toJson() => {
        'host': host,
        'token': token,
        if (directoryUrl != null) 'directory_url': directoryUrl,
        'paired_at': pairedAt,
        'needs_pairing': needsPairing,
      };

  factory MachineRecord.fromJson(Map<String, Object?> json) => MachineRecord(
        host: json['host'] as String,
        token: json['token'] as String,
        directoryUrl: json['directory_url'] as String?,
        pairedAt: json['paired_at'] as String? ?? '',
        needsPairing: json['needs_pairing'] as bool? ?? false,
      );
}

final class InstanceRecord {
  final String machineHost;
  final String? workspaceId;
  final String displayName;
  final String url;
  final String? lastSeen;
  final bool lastOnline;
  final bool inUse;

  /// Last probe returned 404 — a 1.0 desktop, still connectable.
  final bool lastUnknown;

  const InstanceRecord({
    required this.machineHost,
    this.workspaceId,
    required this.displayName,
    required this.url,
    this.lastSeen,
    this.lastOnline = false,
    this.inUse = false,
    this.lastUnknown = false,
  });

  InstanceKey get key => InstanceKey(machineHost, workspaceId);

  int get port => Uri.tryParse(url)?.port ?? 0;

  InstanceRecord copyWith({
    String? workspaceId,
    String? displayName,
    String? url,
    String? lastSeen,
    bool? lastOnline,
    bool? inUse,
    bool? lastUnknown,
  }) =>
      InstanceRecord(
        machineHost: machineHost,
        workspaceId: workspaceId ?? this.workspaceId,
        displayName: displayName ?? this.displayName,
        url: url ?? this.url,
        lastSeen: lastSeen ?? this.lastSeen,
        lastOnline: lastOnline ?? this.lastOnline,
        inUse: inUse ?? this.inUse,
        lastUnknown: lastUnknown ?? this.lastUnknown,
      );

  Map<String, Object?> toJson() => {
        'machine_host': machineHost,
        if (workspaceId != null) 'workspace_id': workspaceId,
        'display_name': displayName,
        'url': url,
        if (lastSeen != null) 'last_seen': lastSeen,
        'last_online': lastOnline,
        'in_use': inUse,
        'last_unknown': lastUnknown,
      };

  factory InstanceRecord.fromJson(Map<String, Object?> json) => InstanceRecord(
        machineHost: json['machine_host'] as String,
        workspaceId: json['workspace_id'] as String?,
        displayName: json['display_name'] as String,
        url: json['url'] as String,
        lastSeen: json['last_seen'] as String?,
        lastOnline: json['last_online'] as bool? ?? false,
        inUse: json['in_use'] as bool? ?? false,
        lastUnknown: json['last_unknown'] as bool? ?? false,
      );
}

final class InstanceKey {
  final String machineHost;
  final String? workspaceId;
  const InstanceKey(this.machineHost, this.workspaceId);

  @override
  bool operator ==(Object other) =>
      other is InstanceKey &&
      other.machineHost == machineHost &&
      other.workspaceId == workspaceId;

  @override
  int get hashCode => Object.hash(machineHost, workspaceId);
}

enum InstanceChip { online, inUse, offline, unknown, needsPairing }

final class StoreDocument {
  final int v;
  final List<MachineRecord> machines;
  final List<InstanceRecord> instances;
  final InstanceKey? lastInstance;

  const StoreDocument({
    this.v = 2,
    this.machines = const [],
    this.instances = const [],
    this.lastInstance,
  });

  StoreDocument copyWith({
    List<MachineRecord>? machines,
    List<InstanceRecord>? instances,
    InstanceKey? lastInstance,
    bool clearLast = false,
  }) =>
      StoreDocument(
        v: v,
        machines: machines ?? this.machines,
        instances: instances ?? this.instances,
        lastInstance: clearLast ? null : (lastInstance ?? this.lastInstance),
      );

  Map<String, Object?> toJson() => {
        'v': v,
        'machines': [for (final m in machines) m.toJson()],
        'instances': [for (final i in instances) i.toJson()],
        if (lastInstance != null)
          'last_instance': {
            'machine_host': lastInstance!.machineHost,
            'workspace_id': lastInstance!.workspaceId,
          },
      };

  factory StoreDocument.fromJson(Map<String, Object?> json) {
    InstanceKey? last;
    final rawLast = json['last_instance'];
    if (rawLast is Map) {
      final lastMap = Map<String, Object?>.from(rawLast);
      last = InstanceKey(
        lastMap['machine_host'] as String,
        lastMap['workspace_id'] as String?,
      );
    }
    return StoreDocument(
      v: json['v'] as int? ?? 2,
      machines: [
        for (final m in json['machines'] as List? ?? const [])
          MachineRecord.fromJson(Map<String, Object?>.from(m as Map))
      ],
      instances: [
        for (final i in json['instances'] as List? ?? const [])
          InstanceRecord.fromJson(Map<String, Object?>.from(i as Map))
      ],
      lastInstance: last,
    );
  }
}

final class InstanceStore {
  final KvStore kv;
  StoreDocument doc = const StoreDocument();

  InstanceStore({KvStore? kv}) : kv = kv ?? const SecureKv();

  Future<void> load() async {
    final raw = await kv.read(instancesV2Key);
    if (raw != null) {
      try {
        doc = StoreDocument.fromJson(
            Map<String, Object?>.from(jsonDecode(raw) as Map));
      } on Object {
        doc = const StoreDocument();
      }
    }
    await _migrateLegacy();
  }

  Future<void> _migrateLegacy() async {
    final url = await kv.read(legacyUrlKey);
    final token = await kv.read(legacyTokenKey);
    if (url == null || token == null) return;
    if (doc.machines.isNotEmpty || doc.instances.isNotEmpty) {
      await _deleteLegacy();
      return;
    }
    final host = Uri.tryParse(url)?.host ?? url;
    final workspace = await kv.read(legacyWorkspaceKey) ?? '';
    doc = StoreDocument(
      machines: [
        MachineRecord(
          host: host,
          token: token,
          pairedAt: DateTime.now().toUtc().toIso8601String(),
        )
      ],
      instances: [
        InstanceRecord(
          machineHost: host,
          displayName: workspace.isEmpty ? host : workspace,
          url: url,
        )
      ],
      lastInstance: InstanceKey(host, null),
    );
    await persist();
    await _deleteLegacy();
  }

  Future<void> _deleteLegacy() async {
    await kv.delete(legacyUrlKey);
    await kv.delete(legacyTokenKey);
    await kv.delete(legacyWorkspaceKey);
  }

  Future<void> persist() async {
    await kv.write(instancesV2Key, jsonEncode(doc.toJson()));
  }

  MachineRecord? machine(String host) {
    for (final m in doc.machines) {
      if (m.host == host) return m;
    }
    return null;
  }

  InstanceRecord? instance(InstanceKey key) {
    for (final i in doc.instances) {
      if (i.key == key) return i;
    }
    return null;
  }

  Future<void> upsertMachine(MachineRecord record) async {
    final machines = [...doc.machines];
    final idx = machines.indexWhere((m) => m.host == record.host);
    if (idx >= 0) {
      machines[idx] = record;
    } else {
      machines.add(record);
    }
    doc = doc.copyWith(machines: machines);
    await persist();
  }

  Future<void> upsertInstance(InstanceRecord record) async {
    final instances = [...doc.instances];
    final idx = instances.indexWhere((i) {
      if (i.machineHost != record.machineHost) return false;
      if (record.workspaceId != null && i.workspaceId != null) {
        return i.workspaceId == record.workspaceId;
      }
      return i.url == record.url;
    });
    if (idx >= 0) {
      final prev = instances[idx];
      instances[idx] = prev.copyWith(
        workspaceId: record.workspaceId ?? prev.workspaceId,
        displayName: record.displayName,
        url: record.url,
        lastSeen: record.lastSeen ?? prev.lastSeen,
        lastOnline: record.lastOnline,
        inUse: record.inUse,
        lastUnknown: record.lastUnknown,
      );
    } else {
      instances.add(record);
    }
    doc = doc.copyWith(instances: instances);
    await persist();
  }

  Future<void> setLastInstance(InstanceKey key) async {
    doc = doc.copyWith(lastInstance: key);
    await persist();
  }

  Future<void> forgetInstance(InstanceKey key) async {
    doc = doc.copyWith(
      instances: [
        for (final i in doc.instances)
          if (i.key != key) i
      ],
      clearLast: doc.lastInstance == key,
    );
    await persist();
  }

  Future<void> forgetMachine(String host) async {
    doc = doc.copyWith(
      machines: [
        for (final m in doc.machines)
          if (m.host != host) m
      ],
      instances: [
        for (final i in doc.instances)
          if (i.machineHost != host) i
      ],
      clearLast: doc.lastInstance?.machineHost == host,
    );
    await persist();
  }

  Future<void> markMachineNeedsPairing(String host) async {
    final m = machine(host);
    if (m == null) return;
    await upsertMachine(m.copyWith(needsPairing: true));
  }

  InstanceChip chipFor(InstanceRecord inst) {
    final m = machine(inst.machineHost);
    if (m != null && m.needsPairing) return InstanceChip.needsPairing;
    if (inst.lastUnknown) return InstanceChip.unknown;
    if (!inst.lastOnline) return InstanceChip.offline;
    if (inst.inUse) return InstanceChip.inUse;
    return InstanceChip.online;
  }
}
