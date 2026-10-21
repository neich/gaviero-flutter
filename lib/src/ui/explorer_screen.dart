import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import 'chat_screen.dart' show ConnectionBanner;
import 'file_view_screen.dart';

/// Read-only workspace tree. Roots mirror the desktop explorer / `@`
/// completion; tapping a folder expands it, tapping a file opens the viewer.
/// Servers without `file_browser` get an update message and no requests.
class ExplorerScreen extends StatefulWidget {
  final RemoteController controller;

  const ExplorerScreen({super.key, required this.controller});

  @override
  State<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends State<ExplorerScreen> {
  final _roots = <DirectoryEntry>[];
  final _children = <String, List<DirectoryEntry>>{};
  final _expanded = <String>{};
  final _loading = <String>{};
  String? _error;
  bool _truncated = false;
  int _generation = 0;
  bool _wasConnected = false;

  RemoteConnection get _connection => widget.controller.connection;
  bool get _supported => widget.controller.supportsFileBrowser;
  bool get _connected => _connection.phase == ConnectionPhase.connected;

  @override
  void initState() {
    super.initState();
    _connection.addListener(_connectionChanged);
    _connectionChanged();
  }

  void _connectionChanged() {
    if (!mounted) return;
    final connected = _connected;
    if (!connected) {
      // Drop everything: a stale tree from the previous instance must never
      // be tappable after a reconnect.
      _generation++;
      _roots.clear();
      _children.clear();
      _expanded.clear();
      _loading.clear();
      _truncated = false;
      _error = null;
    } else if (!_wasConnected) {
      // First connect, or a reconnect: reload the roots.
      unawaited(_loadRoots());
    }
    _wasConnected = connected;
    setState(() {});
  }

  Future<void> _loadRoots() async {
    if (!_connected || !_supported) return;
    final generation = _generation;
    final instanceId = _connection.instanceId;
    try {
      final outcome = await widget.controller.requestDirectory(null);
      if (!mounted ||
          generation != _generation ||
          instanceId != _connection.instanceId) {
        return;
      }
      if (outcome is CommandOk) {
        final listing = DirectoryListing.fromJson(
          outcome.result.result as Map<String, Object?>,
        );
        setState(() {
          _roots
            ..clear()
            ..addAll(listing.roots);
          _truncated = listing.truncated;
          _error = null;
        });
      } else if (outcome is CommandFail) {
        setState(() => _error = outcome.error.message);
      } else {
        setState(() => _error = 'Connection lost. Reconnecting…');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Unable to read the workspace.');
      }
    }
  }

  Future<void> _loadChildren(String path) async {
    if (!_connected || !_supported || _loading.contains(path)) return;
    final generation = _generation;
    final instanceId = _connection.instanceId;
    setState(() => _loading.add(path));
    try {
      final outcome = await widget.controller.requestDirectory(path);
      if (!mounted ||
          generation != _generation ||
          instanceId != _connection.instanceId) {
        return;
      }
      if (outcome is CommandOk) {
        final listing = DirectoryListing.fromJson(
          outcome.result.result as Map<String, Object?>,
        );
        setState(() {
          _children[path] = listing.entries;
          _expanded.add(path);
          _truncated = _truncated || listing.truncated;
          _error = null;
        });
      } else if (outcome is CommandFail) {
        setState(() => _error = outcome.error.message);
      } else {
        setState(() => _error = 'Connection lost. Reconnecting…');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Unable to read this folder.');
      }
    } finally {
      if (mounted) setState(() => _loading.remove(path));
    }
  }

  void _tap(DirectoryEntry entry) {
    if (_loading.contains(entry.path)) return;
    if (!entry.isDir) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FileViewScreen(
            controller: widget.controller,
            path: entry.path,
            name: entry.name,
          ),
        ),
      );
      return;
    }
    if (_expanded.contains(entry.path)) {
      setState(() => _expanded.remove(entry.path));
    } else if (_children[entry.path] == null) {
      unawaited(_loadChildren(entry.path));
    } else {
      setState(() => _expanded.add(entry.path));
    }
  }

  List<_Row> _visibleRows() {
    final rows = <_Row>[];
    void walk(List<DirectoryEntry> entries, int depth) {
      for (final entry in entries) {
        rows.add(_Row(entry, depth));
        if (entry.isDir && _expanded.contains(entry.path)) {
          final children = _children[entry.path];
          if (children != null) walk(children, depth + 1);
        }
      }
    }

    walk(_roots, 0);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visibleRows();
    final loading = _connected && _supported && rows.isEmpty && _error == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Explorer')),
      body: SafeArea(
        child: Column(
          children: [
            ConnectionBanner(
              connection: _connection,
              instanceName: widget.controller.current?.displayName,
            ),
            if (_connected && !_supported)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Update Gaviero on this computer to browse workspace files.',
                ),
              )
            else ...[
              if (_error != null)
                Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          final expanded = _expanded.contains(row.entry.path);
                          final busy = _loading.contains(row.entry.path);
                          return ListTile(
                            key: ValueKey('explorer:${row.entry.path}'),
                            dense: true,
                            contentPadding: EdgeInsets.only(
                              left: 16.0 * row.depth,
                              right: 16,
                            ),
                            leading: Icon(
                              row.entry.isDir
                                  ? (expanded
                                        ? Icons.folder_open
                                        : Icons.folder_outlined)
                                  : Icons.description_outlined,
                            ),
                            title: Text(
                              row.entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: !row.entry.isDir && row.entry.size != null
                                ? Text(_fileSize(row.entry.size!))
                                : null,
                            trailing: busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : null,
                            onTap: _connected ? () => _tap(row.entry) : null,
                          );
                        },
                      ),
              ),
              if (_truncated)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text('Only the first 1000 entries are shown.'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _connection.removeListener(_connectionChanged);
    super.dispose();
  }
}

class _Row {
  final DirectoryEntry entry;
  final int depth;

  const _Row(this.entry, this.depth);
}

String _fileSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
