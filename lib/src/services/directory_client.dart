/// Per-machine instance discovery (Plan D §3.2). UI never awaits this
/// beyond a spinner; each request has a 3 s timeout.
library;

import 'dart:convert';
import 'dart:io';

import '../protocol/directory.dart';
import '../protocol/version.dart';
import 'instance_store.dart';

typedef DirectoryFetcher = Future<DirectoryFetchResult> Function(
    Uri url, String bearerToken);

final class DirectoryFetchResult {
  final int status;
  final String body;
  const DirectoryFetchResult(this.status, this.body);
}

/// `dart:io` `HttpClient` with default certificate validation — Tailscale
/// certs chain to Let's Encrypt, so no pinning.
Future<DirectoryFetchResult> dartIoDirectoryFetch(
    Uri url, String bearerToken) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 3));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearerToken');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final resp = await req.close().timeout(const Duration(seconds: 3));
    final body = await resp.transform(utf8.decoder).join();
    return DirectoryFetchResult(resp.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

final class _MachineProbe {
  final String host;
  final bool unauthorized;
  final List<InstanceRecord> online;
  final Set<InstanceKey> unknown;

  const _MachineProbe({
    required this.host,
    this.unauthorized = false,
    this.online = const [],
    this.unknown = const {},
  });
}

final class DirectoryClient {
  final DirectoryFetcher fetch;
  DirectoryClient({DirectoryFetcher? fetch})
      : fetch = fetch ?? dartIoDirectoryFetch;

  Future<void> refresh(InstanceStore store) async {
    final machines = [...store.doc.machines];
    final known = [...store.doc.instances];
    final results = await Future.wait([
      for (final machine in machines)
        _probeMachine(
          machine,
          [
            for (final i in known)
              if (i.machineHost == machine.host) i
          ],
        ),
    ]);
    for (final result in results) {
      await _apply(store, result);
    }
  }

  Future<void> _apply(InstanceStore store, _MachineProbe result) async {
    if (result.unauthorized) {
      await store.markMachineNeedsPairing(result.host);
      return;
    }
    final seen = <InstanceKey>{};
    for (final rec in result.online) {
      await store.upsertInstance(rec);
      seen.add(rec.key);
    }
    for (final key in result.unknown) {
      seen.add(key);
      final existing = store.instance(key);
      if (existing == null) continue;
      await store.upsertInstance(existing.copyWith(
        lastOnline: false,
        lastUnknown: true,
        inUse: false,
      ));
    }
    final leftover = [
      for (final i in store.doc.instances)
        if (i.machineHost == result.host && !seen.contains(i.key)) i
    ];
    for (final i in leftover) {
      await store.upsertInstance(i.copyWith(
        lastOnline: false,
        lastUnknown: false,
        inUse: false,
      ));
    }
  }

  Future<_MachineProbe> _probeMachine(
      MachineRecord machine, List<InstanceRecord> known) async {
    final online = <InstanceRecord>[];
    final unknown = <InstanceKey>{};
    var unauthorized = false;
    final seenOnline = <InstanceKey>{};

    Future<void> probe(Uri url, {InstanceKey? fallbackKey}) async {
      if (unauthorized) return;
      DirectoryFetchResult result;
      try {
        result =
            await fetch(url, machine.token).timeout(const Duration(seconds: 3));
      } on Object {
        return;
      }
      if (result.status == 401) {
        unauthorized = true;
        return;
      }
      if (result.status == 404) {
        if (fallbackKey != null) unknown.add(fallbackKey);
        return;
      }
      if (result.status != 200) return;
      final InstanceDirectory dir;
      try {
        dir = InstanceDirectory.fromJson(
            Map<String, Object?>.from(jsonDecode(result.body) as Map));
      } on Object {
        return;
      }
      final now = DateTime.now().toUtc().toIso8601String();
      for (final info in dir.instances) {
        final rec = InstanceRecord(
          machineHost: machine.host,
          workspaceId: info.workspace.id,
          displayName: info.workspace.displayName,
          url: info.url,
          lastSeen: now,
          lastOnline: true,
          lastUnknown: false,
          inUse: info.clientConnected,
        );
        online.add(rec);
        seenOnline.add(rec.key);
      }
    }

    if (machine.directoryUrl != null) {
      final uri = Uri.tryParse(machine.directoryUrl!);
      if (uri != null) await probe(uri);
    }
    if (unauthorized) {
      return _MachineProbe(host: machine.host, unauthorized: true);
    }
    for (final inst in known) {
      if (seenOnline.contains(inst.key)) continue;
      final origin = Uri.tryParse(inst.url);
      if (origin == null) continue;
      final probeUrl = origin.replace(
        scheme: 'https',
        path: instancesPath,
        query: '',
        fragment: '',
      );
      await probe(probeUrl, fallbackKey: inst.key);
      if (unauthorized) {
        return _MachineProbe(host: machine.host, unauthorized: true);
      }
    }
    return _MachineProbe(
      host: machine.host,
      online: online,
      unknown: unknown,
    );
  }
}
