/// D5: notification payload and copy include workspace + conversation.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/protocol.dart';
import 'package:gaviero_remote/src/services/notifications.dart';

void main() {
  test('payload encodes machine, workspace, and conversation', () {
    expect(
      NotificationService.encodePayload('alpha.gaviero.example.com', 'ws1', 'c9'),
      'alpha.gaviero.example.com|ws1|c9',
    );
    expect(
      NotificationService.decodePayload('alpha.gaviero.example.com|ws1|c9'),
      ('alpha.gaviero.example.com', 'ws1', 'c9'),
    );
    expect(
      NotificationService.decodePayload('alpha.gaviero.example.com||c9'),
      ('alpha.gaviero.example.com', '', 'c9'),
    );
  });

  test('waiting and finished alerts use distinct channels shared with the '
      'native relay service', () {
    expect(AlertChannel.waiting.id, isNot(AlertChannel.finished.id));
    final kotlin = File(
      'android/app/src/main/kotlin/dev/gaviero/gaviero_remote/'
      'RelayAlertService.kt',
    ).readAsStringSync();
    expect(kotlin, contains('CHANNEL_WAITING = "${AlertChannel.waiting.id}"'));
    expect(kotlin, contains('CHANNEL_FINISHED = "${AlertChannel.finished.id}"'));
    // Same display names, so the system settings never show two spellings.
    expect(kotlin, contains('"${AlertChannel.waiting.name}"'));
    expect(kotlin, contains('"${AlertChannel.finished.name}"'));
    for (final legacy in AlertChannel.legacyIds) {
      expect(legacy, isNot(anyOf(AlertChannel.waiting.id, AlertChannel.finished.id)));
    }
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
