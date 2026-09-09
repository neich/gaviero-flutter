/// D5: notification payload and copy include workspace + conversation.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/protocol.dart';
import 'package:gaviero_remote/src/services/notifications.dart';

void main() {
  test('payload encodes machine, workspace, and conversation', () {
    expect(
      NotificationService.encodePayload('alpha.tailnet.ts.net', 'ws1', 'c9'),
      'alpha.tailnet.ts.net|ws1|c9',
    );
    expect(
      NotificationService.decodePayload('alpha.tailnet.ts.net|ws1|c9'),
      ('alpha.tailnet.ts.net', 'ws1', 'c9'),
    );
    expect(
      NotificationService.decodePayload('alpha.tailnet.ts.net||c9'),
      ('alpha.tailnet.ts.net', '', 'c9'),
    );
  });

  test('permission and streaming bodies name workspace and conversation', () {
    const request = PermissionRequest(
      convId: 'c1',
      requestId: 'r1',
      toolName: 'Bash',
      description: 'ls',
      input: {},
    );
    expect(
      NotificationService.permissionTitle('gaviero'),
      contains('gaviero'),
    );
    expect(
      NotificationService.permissionBody(
        conversationTitle: 'Fix the gate',
        request: request,
      ),
      contains('Fix the gate'),
    );
    expect(
      NotificationService.streamingBody(
        conversationTitle: 'Fix the gate',
        ended: const StreamingEnded(
          convId: 'c1',
          turnId: 't1',
          cancelled: false,
          proposalCount: 0,
        ),
      ),
      allOf(contains('Fix the gate'), contains('complete')),
    );
  });
}
