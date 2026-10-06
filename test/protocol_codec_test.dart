/// B2 verification: round-trip every Plan A fixture, tolerate unknown frame
/// types and unknown fields, detect a protocol-major mismatch, and pin the
/// Dart constants to the vendored schema.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gaviero_remote/src/protocol/protocol.dart';
import 'package:gaviero_remote/src/util/utf8_spans.dart';

/// Structural JSON equality — key order does not matter, presence does.
bool deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

Map<String, Object?> readFixture(String side, String name) {
  final file = File('protocol/fixtures/$side/$name.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

List<String> fixtureNames(String side) {
  final dir = Directory('protocol/fixtures/$side');
  return dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
      .toList()
    ..sort();
}

void main() {
  group('vendored schema constants', () {
    final schema = jsonDecode(
            File('protocol/protocol.schema.json').readAsStringSync())
        as Map<String, Object?>;

    test('PROTOCOL_VERSION matches the schema', () {
      final wire = ProtocolVersion.fromJson(
          schema['protocol_version'] as Map<String, Object?>);
      expect(protocolVersion, wire);
    });

    test('subprotocol and path match the schema', () {
      expect(wsSubprotocol, schema['subprotocol']);
      expect(wsPath, schema['ws_path']);
    });

    test('instances path matches the schema (1.1)', () {
      expect(instancesPath, schema['instances_path']);
    });
  });

  group('1.1 additions (D1)', () {
    test('the vendored hello fixture is the 1.1 shape', () {
      final hello =
          ServerEnvelope.fromJson(readFixture('server', 'hello')).payload
              as Hello;
      expect(hello.capabilities, containsAll(['latest_page', 'instances']));
      expect(hello.supportsLatestPage, isTrue);
      expect(hello.supportsInstances, isTrue);
      expect(hello.machine?.host, 'host.tailnet.ts.net');
      expect(hello.machine?.directoryUrl,
          'https://host.tailnet.ts.net:49151/v1/instances');
    });

    test('a 1.0 hello without machine decodes and re-encodes without it', () {
      final json = readFixture('server', 'hello');
      json['version'] = {'major': 1, 'minor': 0};
      final payload = json['payload'] as Map<String, Object?>;
      payload.remove('machine');
      payload['protocol_version'] = {'major': 1, 'minor': 0};
      payload['capabilities'] = <String>[];
      final envelope = ServerEnvelope.fromJson(json);
      final hello = envelope.payload as Hello;
      expect(hello.machine, isNull);
      expect(hello.supportsLatestPage, isFalse);
      expect(hello.supportsInstances, isFalse);
      expect(envelope.version.isCompatibleWith(protocolVersion), isTrue,
          reason: 'a 1.0 desktop is still compatible: same major');
      expect(deepEquals(envelope.toJson(), json), isTrue);
      expect(hello.toPayloadJson().containsKey('machine'), isFalse);
    });

    test('a machine without directory_url round-trips without the key', () {
      final json = readFixture('server', 'hello');
      final machine = (json['payload'] as Map<String, Object?>)['machine']
          as Map<String, Object?>;
      machine.remove('directory_url');
      final envelope = ServerEnvelope.fromJson(json);
      expect((envelope.payload as Hello).machine!.directoryUrl, isNull);
      expect(deepEquals(envelope.toJson(), json), isTrue);
    });

    test('request_messages with null before_seq omits the key', () {
      const request = RequestMessages(convId: 'conv-3', limit: 50);
      final payload = request.toPayloadJson();
      expect(payload.containsKey('before_seq'), isFalse);
      expect(payload, {'conv_id': 'conv-3', 'limit': 50});
      final decoded = RequestMessages.fromJson(payload);
      expect(decoded.beforeSeq, isNull);
      // The 1.0 fallback is a plain integer that survives JSON as an int.
      const legacy = RequestMessages(
          convId: 'conv-3', beforeSeq: legacyNewestPageBeforeSeq, limit: 50);
      final wire = jsonDecode(jsonEncode(legacy.toPayloadJson()))
          as Map<String, Object?>;
      expect(wire['before_seq'], 9007199254740991);
    });

    test('the vendored request_messages fixture still carries before_seq',
        () {
      final json = readFixture('client', 'request_messages');
      final payload =
          ClientEnvelope.fromJson(json).payload as RequestMessages;
      expect(payload.beforeSeq, 57);
    });

    test('instances.json decodes, round-trips, and keeps client_connected',
        () {
      final json = readFixture('http', 'instances');
      final directory = InstanceDirectory.fromJson(json);
      expect(directory.protocolVersion, const ProtocolVersion(1, 1));
      expect(directory.host, 'host.tailnet.ts.net');
      expect(directory.instances, hasLength(2));
      expect(directory.instances.map((i) => i.clientConnected), [false, true]);
      expect(directory.instances[1].workspace.displayName, 'gaviero-flutter');
      expect(directory.instances[1].port, 61440);
      expect(deepEquals(directory.toJson(), json), isTrue,
          reason: 're-encoded instances.json differs from the fixture');
    });
  });

  group('client fixture round-trips', () {
    for (final name in fixtureNames('client')) {
      test(name, () {
        final json = readFixture('client', name);
        final envelope = ClientEnvelope.fromJson(json);
        expect(envelope.payload.frameType, json['type']);
        expect(deepEquals(envelope.toJson(), json), isTrue,
            reason: 're-encoded $name differs from the fixture');
      });
    }

    test('there is a fixture for all 17 client frame types', () {
      expect(fixtureNames('client'), hasLength(17));
    });

    test('client_hello carries a literal null instance_id', () {
      final json = readFixture('client', 'client_hello');
      expect(json.containsKey('instance_id'), isTrue);
      expect(json['instance_id'], isNull);
      final encoded =
          ClientEnvelope.fromJson(json).toJson();
      expect(encoded.containsKey('instance_id'), isTrue);
      expect(encoded['instance_id'], isNull);
    });
  });

  group('server fixture round-trips', () {
    for (final name in fixtureNames('server')) {
      test(name, () {
        final json = readFixture('server', name);
        final envelope = ServerEnvelope.fromJson(json);
        expect(envelope.payload.frameType, json['type']);
        expect(envelope.payload, isNot(isA<UnknownServerPayload>()));
        expect(deepEquals(envelope.toJson(), json), isTrue,
            reason: 're-encoded $name differs from the fixture');
      });
    }

    test('there is a fixture for all 23 server frame types', () {
      expect(fixtureNames('server'), hasLength(23));
    });
  });

  group('1.2 turn review', () {
    test('turn_review_pending decodes every field', () {
      final payload = ServerEnvelope.fromJson(
              readFixture('server', 'turn_review_pending'))
          .payload as TurnReviewEvent;
      expect(payload.lifecycle, TurnReviewLifecycle.pending);
      final review = payload.review;
      expect(review.turnId, 'conv-3-1759600000000');
      expect(review.convId, 'conv-3');
      expect(review.outcome, TurnOutcome.completed);
      expect(review.warnings, isEmpty);
      expect(review.files.map((f) => f.path),
          ['src/parser.rs', 'assets/logo.png']);
      final logo = review.files[1];
      expect(logo.change, TurnFileChange.added);
      expect(logo.decision, TurnFileDecision.keep);
      expect(logo.revertible, isTrue);
      expect(logo.binary, isTrue);
      expect(logo.overlapWith, ['conv-1-1759599990000']);
      expect(review.files[0].overlapWith, isEmpty);
      expect(review.files[0].toJson().containsKey('overlap_with'), isFalse,
          reason: 'empty overlap_with is omitted, never emitted');
    });

    test('turn_review_updated carries revert_hunks, outcome, and warnings',
        () {
      final payload = ServerEnvelope.fromJson(
              readFixture('server', 'turn_review_updated'))
          .payload as TurnReviewEvent;
      expect(payload.lifecycle, TurnReviewLifecycle.updated);
      expect(payload.review.outcome, TurnOutcome.cancelled);
      expect(payload.review.files.map((f) => f.decision),
          [TurnFileDecision.revertHunks, TurnFileDecision.revert]);
      expect(payload.review.files[1].change, TurnFileChange.deleted);
      expect(payload.review.warnings, hasLength(1));
    });

    test('turn_review_resolved decodes; empty failed is omitted', () {
      final json = readFixture('server', 'turn_review_resolved');
      final resolved =
          ServerEnvelope.fromJson(json).payload as TurnReviewResolved;
      expect(resolved.turnId, 'conv-3-1759600000000');
      expect(resolved.convId, 'conv-3');
      expect(resolved.kept, 1);
      expect(resolved.reverted, 1);
      expect(resolved.failed.single, startsWith('src/big.bin: '));

      final payload = json['payload'] as Map<String, Object?>
        ..remove('failed')
        ..remove('conv_id');
      final bare = TurnReviewResolved.fromJson(payload);
      expect(bare.failed, isEmpty);
      expect(bare.convId, isNull);
      expect(bare.toPayloadJson(),
          {'turn_id': 'conv-3-1759600000000', 'kept': 1, 'reverted': 1});
    });

    test('a snapshot without open_turn_reviews decodes to none and '
        're-encodes without the key', () {
      final json = readFixture('server', 'snapshot');
      final payload = json['payload'] as Map<String, Object?>;
      expect(payload.containsKey('open_turn_reviews'), isFalse);
      final snapshot = ServerEnvelope.fromJson(json).payload as Snapshot;
      expect(snapshot.openTurnReviews, isEmpty);
      expect(snapshot.toPayloadJson().containsKey('open_turn_reviews'),
          isFalse);
    });

    test('snapshot.open_turn_reviews decodes and round-trips', () {
      final json = readFixture('server', 'snapshot');
      final review = (readFixture('server', 'turn_review_updated')['payload']
          as Map<String, Object?>)['review'];
      (json['payload'] as Map<String, Object?>)['open_turn_reviews'] = [
        review
      ];
      final envelope = ServerEnvelope.fromJson(json);
      final snapshot = envelope.payload as Snapshot;
      expect(snapshot.openTurnReviews.single.turnId, 'conv-3-1759600000000');
      expect(deepEquals(envelope.toJson(), json), isTrue);
    });

    test('values from a newer server decode to unknown instead of dropping '
        'the snapshot, and re-encode verbatim', () {
      final json = readFixture('server', 'snapshot');
      final review = jsonDecode(jsonEncode(
          (readFixture('server', 'turn_review_updated')['payload']
              as Map<String, Object?>)['review'])) as Map<String, Object?>;
      review['outcome'] = 'timed_out';
      final file = (review['files'] as List<Object?>).first
          as Map<String, Object?>;
      file['change'] = 'renamed';
      file['decision'] = 'revert_lines';
      (json['payload'] as Map<String, Object?>)['open_turn_reviews'] = [
        review
      ];

      final envelope = ServerEnvelope.fromJson(json);
      final decoded = (envelope.payload as Snapshot).openTurnReviews.single;
      expect(decoded.outcome, TurnOutcome.unknown);
      expect(decoded.files.first.change, TurnFileChange.unknown);
      expect(decoded.files.first.change.badge, '?');
      expect(decoded.files.first.decision, TurnFileDecision.unknown);
      expect(deepEquals(envelope.toJson(), json), isTrue,
          reason: 'unknown values must re-encode as the server sent them');
    });

    test('turn_review_action encodes path only for per-file actions', () {
      final fixture = ClientEnvelope.fromJson(
              readFixture('client', 'turn_review_action'))
          .payload as TurnReviewAction;
      expect(fixture.action, TurnReviewActionKind.revertFile);
      expect(fixture.path, 'src/parser.rs');
      expect(TurnReviewActionKind.keepFile.needsPath, isTrue);
      expect(TurnReviewActionKind.finalize.needsPath, isFalse);

      const finalize = TurnReviewAction(
          turnId: 't1', action: TurnReviewActionKind.finalize);
      expect(finalize.toPayloadJson(), {'turn_id': 't1', 'action': 'finalize'});
      expect(
          [for (final k in TurnReviewActionKind.values) k.wire],
          ['keep_file', 'revert_file', 'keep_all', 'revert_all', 'finalize']);
    });

    test('the 1.2 error codes decode to known values', () {
      final json = readFixture('server', 'command_error');
      final payload = json['payload'] as Map<String, Object?>;
      payload['code'] = 'turn_review_pending';
      expect((ServerEnvelope.fromJson(json).payload as CommandError).code,
          ErrorCode.turnReviewPending);
      payload['code'] = 'unknown_turn_review';
      final err = ServerEnvelope.fromJson(json).payload as CommandError;
      expect(err.code, ErrorCode.unknownTurnReview);
      expect(err.toPayloadJson()['code'], 'unknown_turn_review');
    });

    test('the schema error-code enum matches ErrorCode', () {
      final schema = File('protocol/protocol.schema.json').readAsStringSync();
      for (final code in ErrorCode.values) {
        if (code == ErrorCode.unrecognized) continue;
        expect(schema, contains('"${code.wire}"'));
      }
    });

    test('the turn_review capability is feature-detected', () {
      final json = readFixture('server', 'hello');
      final payload = json['payload'] as Map<String, Object?>;
      expect((ServerEnvelope.fromJson(json).payload as Hello)
          .hasCapability(Capability.turnReview), isFalse);
      payload['capabilities'] = [
        ...(payload['capabilities'] as List<Object?>),
        'turn_review',
      ];
      expect((ServerEnvelope.fromJson(json).payload as Hello)
          .hasCapability(Capability.turnReview), isTrue);
    });
  });

  group('forward compatibility', () {
    test('an unknown server frame type decodes, never crashes', () {
      final json = readFixture('server', 'cost_update');
      json['type'] = 'brand_new_event_from_1_1';
      json['payload'] = {'anything': true};
      final envelope = ServerEnvelope.fromJson(json);
      final payload = envelope.payload;
      expect(payload, isA<UnknownServerPayload>());
      expect((payload as UnknownServerPayload).type,
          'brand_new_event_from_1_1');
    });

    test('unknown fields are ignored at envelope and payload level', () {
      final json = readFixture('server', 'hello');
      json['minted_in_1_1'] = 'ignored';
      (json['payload'] as Map<String, Object?>)['also_new'] = [1, 2, 3];
      final envelope = ServerEnvelope.fromJson(json);
      final hello = envelope.payload as Hello;
      expect(hello.instanceId, 'a3f9c2e14b7d8650');
      expect(hello.allowedSlashCommands, contains('/model'));
    });

    test('an unknown command_error code degrades, keeps the raw string', () {
      final json = readFixture('server', 'command_error');
      (json['payload'] as Map<String, Object?>)['code'] = 'code_from_1_1';
      final err = ServerEnvelope.fromJson(json).payload as CommandError;
      expect(err.code, ErrorCode.unrecognized);
      expect(err.rawCode, 'code_from_1_1');
    });

    test('a protocol-major mismatch is detectable, decode does not throw', () {
      final json = readFixture('server', 'hello');
      json['version'] = {'major': 2, 'minor': 0};
      final envelope = ServerEnvelope.fromJson(json);
      expect(envelope.version.isCompatibleWith(protocolVersion), isFalse);
    });
  });

  group('UTF-8 byte offsets (message_complete fixture)', () {
    // The fixture deliberately contains non-ASCII content with hand-verified
    // byte offsets; String.substring on these offsets would be wrong.
    final json = readFixture('server', 'message_complete');
    final message =
        (ServerEnvelope.fromJson(json).payload as MessageComplete).message;

    test('spans slice to the expected tokens', () {
      final text = Utf8Text(message.content);
      final block = message.codeBlocks.single;
      expect(text.slice(block.spans[0].startByte, block.spans[0].endByte),
          'let');
      expect(text.slice(block.spans[1].startByte, block.spans[1].endByte),
          '"héllo 🌍"');
    });

    test('block range covers the fenced block including fences', () {
      final text = Utf8Text(message.content);
      final block = message.codeBlocks.single;
      final fenced = text.slice(block.startByte, block.endByte);
      expect(fenced, startsWith('```rust\n'));
      expect(fenced.trimRight(), endsWith('```'));
    });

    test('classifyRuns reassembles the block exactly', () {
      final text = Utf8Text(message.content);
      final block = message.codeBlocks.single;
      final runs = classifyRuns(
        text,
        block.startByte,
        block.endByte,
        block.spans.map((s) => (
              startByte: s.startByte,
              endByte: s.endByte,
              className: s.className,
            )),
      );
      expect(runs.map((r) => r.text).join(),
          text.slice(block.startByte, block.endByte));
      expect(runs.where((r) => r.className == 'keyword').single.text, 'let');
      expect(runs.where((r) => r.className == 'string').single.text,
          '"héllo 🌍"');
    });
  });
}
