/// The machines' `gaviero-cli` runs (1.11 `cli_runs`), read over HTTPS from
/// any instance listener of each machine — the same route, token and pinned
/// CA as the instance directory ([DirectoryClient]). Read-only.
library;

import 'dart:convert';

import '../protocol/cli_runs.dart';
import '../protocol/swarm.dart';
import '../protocol/version.dart';
import 'directory_client.dart';
import 'instance_store.dart';

/// How one machine answered the list request.
enum CliRunsStatus {
  ok,

  /// The machine's Gaviero predates CLI runs (404).
  unsupported,

  /// The machine token was refused (401): pair again.
  unauthorized,

  /// No instance listener answered (offline, timeout, bad reply).
  unreachable,
}

final class MachineCliRuns {
  final MachineRecord machine;
  final CliRunsStatus status;
  final List<CliRunSummary> runs;

  const MachineCliRuns(this.machine, this.status, [this.runs = const []]);
}

/// One run read: the snapshot, or why there is none.
final class CliRunRead {
  final SwarmSnapshot? snapshot;
  final CliRunsStatus status;

  /// The run is gone from the machine (404 on a server that lists runs).
  final bool missing;

  const CliRunRead(this.status, {this.snapshot, this.missing = false});
}

final class CliRunsClient {
  /// Injected by tests; null ⇒ [dartIoDirectoryFetch] with the machine's
  /// pinned CA.
  final DirectoryFetcher? _fetch;
  CliRunsClient({this._fetch});

  Future<DirectoryFetchResult> _get(MachineRecord machine, Uri url) {
    final fetch = _fetch;
    return (fetch != null
            ? fetch(url, machine.token)
            : dartIoDirectoryFetch(
                url,
                machine.token,
                tlsCa: machine.tlsCa,
                relayHost: machine.relayHost,
              ))
        .timeout(const Duration(seconds: 4));
  }

  /// Origins to ask for [machine]: its directory route first, then each
  /// stored instance's route (any listener serves the whole machine).
  static List<Uri> originsFor(
    MachineRecord machine,
    Iterable<InstanceRecord> instances,
  ) {
    final origins = <Uri>[];
    void add(String? raw) {
      final uri = raw == null ? null : Uri.tryParse(raw);
      if (uri == null || uri.host.isEmpty) return;
      final origin = Uri(
        scheme: 'https',
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      );
      if (!origins.contains(origin)) origins.add(origin);
    }

    add(machine.directoryUrl);
    for (final inst in instances) {
      if (inst.machineHost == machine.host) add(inst.url);
    }
    return origins;
  }

  /// Every paired machine's runs, in store order.
  Future<List<MachineCliRuns>> list(InstanceStore store) {
    final instances = store.doc.instances;
    return Future.wait([
      for (final machine in store.doc.machines)
        listMachine(machine, originsFor(machine, instances)),
    ]);
  }

  Future<MachineCliRuns> listMachine(
    MachineRecord machine,
    List<Uri> origins,
  ) async {
    if (machine.needsPairing) {
      return MachineCliRuns(machine, CliRunsStatus.unauthorized);
    }
    var status = CliRunsStatus.unreachable;
    for (final origin in origins) {
      final DirectoryFetchResult result;
      try {
        result = await _get(machine, origin.replace(path: cliRunsPath));
      } on Object {
        continue;
      }
      switch (result.status) {
        case 200:
          try {
            final list = CliRunList.fromJson(
              Map<String, Object?>.from(jsonDecode(result.body) as Map),
            );
            return MachineCliRuns(machine, CliRunsStatus.ok, list.runs);
          } on Object {
            continue;
          }
        case 401:
          return MachineCliRuns(machine, CliRunsStatus.unauthorized);
        case 404:
          // An older listener; another instance may be newer.
          status = CliRunsStatus.unsupported;
        default:
          continue;
      }
    }
    return MachineCliRuns(machine, status);
  }

  /// One run, the way `request_swarm` reads the SWARM panel's.
  Future<CliRunRead> read(
    MachineRecord machine,
    List<Uri> origins,
    String id, {
    String? agentId,
    String? outputToken,
  }) async {
    final query = {'agent_id': ?agentId, 'output_token': ?outputToken};
    var status = CliRunsStatus.unreachable;
    // A 404 may come from an older listener; only when no route has the
    // run is it gone.
    var notFound = false;
    for (final origin in origins) {
      final url = origin.replace(
        path: '$cliRunsPath/${Uri.encodeComponent(id)}',
        queryParameters: query.isEmpty ? null : query,
      );
      final DirectoryFetchResult result;
      try {
        result = await _get(machine, url);
      } on Object {
        continue;
      }
      switch (result.status) {
        case 200:
          try {
            final snapshot = SwarmSnapshot.fromJson(
              Map<String, Object?>.from(jsonDecode(result.body) as Map),
            );
            return CliRunRead(CliRunsStatus.ok, snapshot: snapshot);
          } on Object {
            continue;
          }
        case 401:
          return const CliRunRead(CliRunsStatus.unauthorized);
        case 404:
          notFound = true;
        default:
          continue;
      }
    }
    if (notFound) return const CliRunRead(CliRunsStatus.ok, missing: true);
    return CliRunRead(status);
  }
}
