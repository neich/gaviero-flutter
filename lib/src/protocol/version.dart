/// Wire protocol version, subprotocol, and paths — vendored from
/// `protocol/protocol.schema.json` (Plan A owns 1.0, Plan C owns the 1.1
/// additions; a codec test asserts these constants match the vendored
/// schema).
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

const protocolVersion = ProtocolVersion(1, 1);
const wsSubprotocol = 'gaviero.v1';
const wsPath = '/v1/ws';

/// `GET /v1/instances` (1.1) — on every instance listener and on the machine
/// directory port.
const instancesPath = '/v1/instances';

/// Default machine directory port (PROTOCOL.md header).
const defaultDirectoryPort = 49151;

/// How far past a stored instance port we probe when that listener is gone
/// (matches gaviero-tui `PORT_WINDOW`: derived port + 0..9).
const instancePortWindow = 10;

/// `hello.capabilities` entries (1.1). Feature-detect with these, never with
/// the minor version.
abstract final class Capability {
  /// `request_messages.before_seq` may be omitted to get the newest page.
  static const latestPage = 'latest_page';

  /// The instance serves `GET /v1/instances`.
  static const instances = 'instances';
}

/// `before_seq` to send to a server without [Capability.latestPage]: 2^53 − 1,
/// which a 1.0 server parses as a plain `u64` and answers with the tail.
const legacyNewestPageBeforeSeq = 9007199254740991;
