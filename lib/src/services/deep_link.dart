/// Parse gaviero-remote://open?host=&workspace=&conv= without the
/// app_links plugin so unit tests stay pure Dart.
library;

final class OpenTarget {
  final String host;
  final String workspaceId;
  final String convId;

  const OpenTarget({
    required this.host,
    required this.workspaceId,
    required this.convId,
  });
}

/// Returns null when the URI is not a Gaviero Remote open link.
/// Missing query keys become empty strings (the controller then opens
/// the instance picker).
OpenTarget? parseGavieroRemoteOpen(Uri uri) {
  if (uri.scheme != 'gaviero-remote') return null;
  if (uri.host != 'open') return null;
  return OpenTarget(
    host: uri.queryParameters['host'] ?? '',
    workspaceId: uri.queryParameters['workspace'] ?? '',
    convId: uri.queryParameters['conv'] ?? '',
  );
}
