/// Wire protocol version, subprotocol, and path — vendored from
/// `protocol/protocol.schema.json` (Plan A owns the protocol; a codec test
/// asserts these constants match the vendored schema).
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

const protocolVersion = ProtocolVersion(1, 0);
const wsSubprotocol = 'gaviero.v1';
const wsPath = '/v1/ws';
