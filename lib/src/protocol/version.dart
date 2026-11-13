/// Wire protocol version, subprotocol, and paths — vendored from
/// `protocol/protocol.schema.json` (Plan A owns 1.0, Plan C owns the 1.1
/// additions, 1.2 adds turn review, 1.5 turn-review folders, 1.6 permission
/// grants, 1.7 shell history, 1.8 skill completions; a codec test asserts
/// these constants
/// match the vendored schema).
library;

final class ProtocolVersion {
  final int major;
  final int minor;

  const ProtocolVersion(this.major, this.minor);

  factory ProtocolVersion.fromJson(Map<String, Object?> json) =>
      ProtocolVersion(json['major'] as int, json['minor'] as int);

  Map<String, Object?> toJson() => {'major': major, 'minor': minor};

  /// Majors must match; a newer server minor is fine (additive changes only).
  bool isCompatibleWith(ProtocolVersion other) => major == other.major;

  @override
  bool operator ==(Object other) =>
      other is ProtocolVersion && other.major == major && other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);

  @override
  String toString() => '$major.$minor';
}

const protocolVersion = ProtocolVersion(1, 9);
const wsSubprotocol = 'gaviero.v1';
const wsPath = '/v1/ws';

/// `GET /v1/instances` (1.1) — on every instance listener, so any of a
/// machine's relay routes lists all of its instances.
const instancesPath = '/v1/instances';

/// `hello.capabilities` entries (1.1). Feature-detect with these, never with
/// the minor version.
abstract final class Capability {
  /// `request_messages.before_seq` may be omitted to get the newest page.
  static const latestPage = 'latest_page';

  /// The instance serves `GET /v1/instances`.
  static const instances = 'instances';

  /// `request_file_completions` lists workspace paths for `@` references.
  static const fileCompletions = 'file_completions';

  /// 1.2: `turn_review_*` frames, `snapshot.open_turn_reviews`, and the
  /// `turn_review_action` command.
  static const turnReview = 'turn_review';

  /// 1.3: `list_directory` / `read_file` browse the workspace read-only.
  static const fileBrowser = 'file_browser';

  /// 1.4: `permission_decision.grant = mcp_server_turn` allows a request's
  /// `mcp_server` for the rest of the current prompt.
  static const permissionTurnGrant = 'permission_turn_grant';

  /// 1.6: `permission_request.grants` lists every standing answer a request
  /// accepts — the desktop's `a` / `A` / `p` keys plus `mcp_server_turn`.
  static const permissionGrants = 'permission_grants';

  /// 1.8: `request_skill_completions` lists catalog skills for a `$skill`
  /// invocation.
  static const skillCompletions = 'skill_completions';
}

/// `before_seq` to send to a server without [Capability.latestPage]: 2^53 − 1,
/// which a 1.0 server parses as a plain `u64` and answers with the tail.
const legacyNewestPageBeforeSeq = 9007199254740991;
