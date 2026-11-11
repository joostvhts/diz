import 'dart:convert';
import 'dart:io';

/// Receives the status updates WiZ bulbs push after a push registration
/// (`syncPilot` on every change, `firstBeat` after a reboot). Nothing is sent
/// back: bulbs don't expect an acknowledgement.
class PushListener {
  PushListener(this._onMessage);

  final void Function(Map<String, Object?> message, InternetAddress from) _onMessage;
  RawDatagramSocket? _socket;

  int get port => _socket!.port;

  /// Binds the UDP socket. Throws [SocketException] if the port is taken.
  Future<void> start({InternetAddress? host, required int port}) async {
    final socket = await RawDatagramSocket.bind(host ?? InternetAddress.anyIPv4, port);
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(datagram.data, allowMalformed: true));
      } on FormatException {
        return; // Bulbs occasionally send non-JSON keep-alives such as "test".
      }
      if (decoded is Map) _onMessage(decoded.cast<String, Object?>(), datagram.address);
    });
  }

  void close() {
    _socket?.close();
    _socket = null;
  }
}
