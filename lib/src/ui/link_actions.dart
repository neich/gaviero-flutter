/// Following Markdown links: web links open in the phone's browser or mail
/// app, workspace paths open the read-only file viewer.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../protocol/protocol.dart';
import '../state/controller.dart';
import '../transport/connection.dart';
import '../util/links.dart';
import 'file_view_screen.dart';

/// Opens a resolved workspace file; [followLink] pushes a viewer on the
/// nearest navigator when none is given.
typedef FileLinkOpener = void Function(FileLink link);

/// Hands a link to the phone. Replaced in tests.
Future<bool> Function(Uri uri) openExternalUrl = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Link handling for every [MarkdownText] below it that has no handler of
/// its own (chat bubbles, review screens). The home screen provides one.
class MarkdownLinks extends InheritedWidget {
  final void Function(BuildContext context, String href) onTap;

  const MarkdownLinks({super.key, required this.onTap, required super.child});

  /// Read once per build, without a dependency: the handler only matters
  /// when a link is tapped.
  static MarkdownLinks? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MarkdownLinks>();

  @override
  bool updateShouldNotify(MarkdownLinks oldWidget) => false;
}

/// Follows [href]. [fromFile] is the workspace path of the document holding
/// the link (relative links resolve against it); without it the path is
/// workspace-relative, as in chat. Failures are shown as a snack bar.
Future<void> followLink(
  BuildContext context,
  RemoteController controller,
  String href, {
  String? fromFile,
  FileLinkOpener? openFile,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void tell(String message) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  var target = resolveLink(href, fromFile: fromFile);
  if (target is NeedsRoots || target is FileLink) {
    if (!controller.supportsFileBrowser) {
      tell('Update Gaviero on this computer to open workspace files.');
      return;
    }
  }
  if (target is NeedsRoots) {
    final roots = await _rootLabels(controller);
    if (!context.mounted) return;
    if (roots == null) {
      tell("Couldn't read the workspace folders.");
      return;
    }
    target = resolveLink(href, roots: roots);
  }
  switch (target) {
    case WebLink(:final uri):
      bool opened;
      try {
        opened = await openExternalUrl(uri);
      } on Object {
        opened = false;
      }
      if (!opened) tell("Couldn't open $uri");
    case UnsupportedLink(:final reason):
      tell(reason);
    case NeedsRoots():
      tell('This workspace has no folders.');
    case FileLink():
      if (openFile != null) {
        openFile(target);
      } else {
        Navigator.of(context).push(fileViewRoute(controller, target));
      }
  }
}

MaterialPageRoute<void> fileViewRoute(
  RemoteController controller,
  FileLink link,
) => MaterialPageRoute(
  builder: (_) => FileViewScreen(
    controller: controller,
    path: link.path,
    name: link.name,
    startLine: link.startLine,
    endLine: link.endLine,
    anchor: link.anchor,
  ),
);

/// The workspace root labels, asked each time (folders can be added on the
/// desktop); null when the desktop could not be reached.
Future<List<String>?> _rootLabels(RemoteController controller) async {
  final outcome = await controller.requestDirectory(null);
  if (outcome is! CommandOk) return null;
  try {
    final listing = DirectoryListing.fromJson(
      outcome.result.result as Map<String, Object?>,
    );
    return [for (final root in listing.roots) root.path];
  } on Object {
    return null;
  }
}
