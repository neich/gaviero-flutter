/// Deep-link parse for ntfy taps (gaviero-remote://open?...).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/services/deep_link.dart';

void main() {
  test('parses host, workspace, and conv', () {
    final target = parseGavieroRemoteOpen(
      Uri.parse(
        'gaviero-remote://open?host=neichtop.tail9b1d28.ts.net&workspace=0b7d245998c0e8c3&conv=c9',
      ),
    );
    expect(target, isNotNull);
    expect(target!.host, 'neichtop.tail9b1d28.ts.net');
    expect(target.workspaceId, '0b7d245998c0e8c3');
    expect(target.convId, 'c9');
  });

  test('missing query keys become empty strings, not null', () {
    final target = parseGavieroRemoteOpen(Uri.parse('gaviero-remote://open'));
    expect(target, isNotNull);
    expect(target!.host, isEmpty);
    expect(target.workspaceId, isEmpty);
    expect(target.convId, isEmpty);
  });

  test('decodes percent-encoded MagicDNS and conv', () {
    final target = parseGavieroRemoteOpen(
      Uri.parse(
        'gaviero-remote://open?host=neichtop.tail9b1d28.ts.net&workspace=ws&conv=conv%2F1',
      ),
    );
    expect(target, isNotNull);
    expect(target!.host, 'neichtop.tail9b1d28.ts.net');
    expect(target.convId, 'conv/1');
  });

  test('rejects other schemes and hosts', () {
    expect(
      parseGavieroRemoteOpen(Uri.parse('https://ntfy.sh/topic')),
      isNull,
    );
    expect(
      parseGavieroRemoteOpen(Uri.parse('gaviero-remote://pair?host=x')),
      isNull,
    );
  });
}
