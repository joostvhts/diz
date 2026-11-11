import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'wiz_protocol.dart';

/// Where a bulb can be reached.
class WizEndpoint {
  const WizEndpoint(this.address, [this.port = wizPort]);

  final InternetAddress address;
  final int port;

  /// Parses `192.168.1.50` or `192.168.1.50:38899`.
  factory WizEndpoint.parse(String text) {
    final parts = text.trim().split(':');
    if (parts.length > 2) throw FormatException('Expected ip or ip:port, got "$text"');
    final address = InternetAddress.tryParse(parts[0]);
    if (address == null || address.type != InternetAddressType.IPv4) {
      throw FormatException('Not an IPv4 address: "$text"');
    }
    final port = parts.length == 2 ? int.tryParse(parts[1]) : wizPort;
    if (port == null || port <= 0 || port > 65535) throw FormatException('Bad port in "$text"');
    return WizEndpoint(address, port);
  }

  @override
  bool operator ==(Object other) =>
      other is WizEndpoint && other.address == address && other.port == port;

  @override
  int get hashCode => Object.hash(address, port);

  @override
  String toString() => port == wizPort ? address.address : '${address.address}:$port';
}

class WizException implements Exception {
  const WizException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The bulb did not answer in time (offline, powered off at the wall, wrong IP).
class WizTimeoutException extends WizException {
  const WizTimeoutException(super.message);
}

/// The bulb answered with an error (e.g. unknown method on old firmware).
class WizErrorResponse extends WizException {
  const WizErrorResponse(this.code, String message) : super(message);
  final int? code;
}

/// One answer to a broadcast probe.
class WizReply {
  const WizReply(this.from, this.message);
  final WizEndpoint from;
  final Map<String, Object?> message;

  Map<String, Object?> get result =>
      (message['result'] is Map) ? (message['result'] as Map).cast<String, Object?>() : const {};
}

/// Sends WiZ messages. An interface so tests can swap in fakes.
abstract interface class WizTransport {
  /// Sends [message] to one bulb and returns the `result` object of its reply.
  /// Retries [attempts] times, waiting a little longer each time.
  Future<Map<String, Object?>> request(
    WizEndpoint to,
    Map<String, Object?> message, {
    int attempts,
    Duration attemptTimeout,
  });

  /// Sends [message] (typically to a broadcast address) and collects every
  /// distinct reply that arrives within [listenFor].
  Future<List<WizReply>> collect(
    WizEndpoint to,
    Map<String, Object?> message, {
    Duration listenFor,
    int repeats,
  });
}

/// [WizTransport] over real UDP sockets. Each call uses its own ephemeral
/// socket, which keeps reply matching trivial and works well with stateful
/// firewalls for unicast traffic.
class UdpWizTransport implements WizTransport {
  @override
  Future<Map<String, Object?>> request(
    WizEndpoint to,
    Map<String, Object?> message, {
    int attempts = 3,
    Duration attemptTimeout = const Duration(milliseconds: 200),
  }) async {
    final method = message['method'];
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final completer = Completer<Map<String, Object?>>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null || completer.isCompleted) return;
      if (datagram.address != to.address) return;
      final decoded = _decode(datagram.data);
      if (decoded == null || decoded['method'] != method) return;
      completer.complete(decoded);
    });

    try {
      final payload = utf8.encode(jsonEncode(message));
      for (var attempt = 1; attempt <= attempts; attempt++) {
        try {
          socket.send(payload, to.address, to.port);
        } on SocketException catch (e) {
          throw WizException('Cannot send to $to: ${e.message}');
        }
        try {
          final reply = await completer.future.timeout(attemptTimeout * attempt);
          final error = reply['error'];
          if (error is Map) {
            throw WizErrorResponse(
              (error['code'] as num?)?.toInt(),
              '$to answered $method with error: ${error['message'] ?? error}',
            );
          }
          final result = reply['result'];
          return result is Map ? result.cast<String, Object?>() : <String, Object?>{};
        } on TimeoutException {
          continue;
        }
      }
      throw WizTimeoutException('$to did not answer $method');
    } finally {
      await sub.cancel();
      socket.close();
    }
  }

  @override
  Future<List<WizReply>> collect(
    WizEndpoint to,
    Map<String, Object?> message, {
    Duration listenFor = const Duration(seconds: 2),
    int repeats = 3,
  }) async {
    final method = message['method'];
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final replies = <WizEndpoint, WizReply>{};
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final decoded = _decode(datagram.data);
      if (decoded == null || decoded['method'] != method) return;
      final from = WizEndpoint(datagram.address, datagram.port);
      replies.putIfAbsent(from, () => WizReply(from, decoded));
    });

    try {
      final payload = utf8.encode(jsonEncode(message));
      final gap = listenFor ~/ repeats;
      for (var i = 0; i < repeats; i++) {
        try {
          socket.send(payload, to.address, to.port);
        } on SocketException catch (e) {
          throw WizException('Cannot send discovery probe to $to: ${e.message}');
        }
        await Future<void>.delayed(gap);
      }
      return replies.values.toList();
    } finally {
      await sub.cancel();
      socket.close();
    }
  }

  static Map<String, Object?>? _decode(List<int> data) {
    try {
      final decoded = jsonDecode(utf8.decode(data, allowMalformed: true));
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }
}
