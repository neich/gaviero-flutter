/// Thin socket abstraction so the connection state machine is testable with
/// a fake. The real implementation is `IOWebSocketChannel` — verified against
/// the installed 3.0.3 to carry BOTH custom upgrade headers and a subprotocol
/// list (PLAN.md §2.4 gate). The bearer token goes in the `Authorization`
/// header and nowhere else; do not "simplify" to the cross-platform
/// `WebSocketChannel.connect`, which cannot send headers.
library;

import 'package:web_socket_channel/io.dart';

import '../protocol/version.dart';

abstract interface class WsSocket {
  Stream<dynamic> get frames;
  void send(String text);
  Future<void> close([int? code, String? reason]);
  int? get closeCode;
  String? get closeReason;
}

typedef WsConnector = Future<WsSocket> Function(Uri url, String bearerToken);

final class IoWsSocket implements WsSocket {
  final IOWebSocketChannel _channel;

  IoWsSocket._(this._channel);

  static Future<WsSocket> connect(Uri url, String bearerToken) async {
    final channel = IOWebSocketChannel.connect(
      url,
      protocols: const [wsSubprotocol],
      headers: {'Authorization': 'Bearer $bearerToken'},
      connectTimeout: const Duration(seconds: 15),
    );
    await channel.ready;
    return IoWsSocket._(channel);
  }

  @override
  Stream<dynamic> get frames => _channel.stream;

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close([int? code, String? reason]) =>
      _channel.sink.close(code, reason);

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;
}
