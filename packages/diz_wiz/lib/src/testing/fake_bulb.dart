import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A WiZ bulb simulator speaking the local UDP protocol. Used by the tests
/// and by `tool/fake_bulb.dart` to develop without real lights.
class FakeBulb {
  FakeBulb({
    required this.mac,
    this.moduleName = 'ESP01_SHRGB1C_31',
    this.firmware = '1.31.0',
    this.cctRange = const [2200, 2700, 6500, 6500],
    this.supportsModelConfig = true,
    this.pushPort = 38900,
    Map<String, Object?>? pilot,
  }) : pilot = pilot ?? {'state': true, 'sceneId': 0, 'temp': 2700, 'dimming': 80};

  /// Port pushes are sent to. Real bulbs always use 38900; tests override it.
  final int pushPort;

  /// Where to push state changes, set by a `registration` with `register: true`.
  InternetAddress? pushTarget;

  /// Number of push registrations received.
  int registrations = 0;

  final String mac;
  final String moduleName;
  final String firmware;
  final List<int> cctRange;
  final bool supportsModelConfig;

  /// Current state as the bulb would report it in `getPilot`.
  final Map<String, Object?> pilot;

  /// When false the bulb ignores everything, like a bulb switched off at the wall.
  bool responding = true;

  /// Number of upcoming requests to silently drop (to exercise retries).
  int dropNext = 0;

  /// Every request received, in order (including dropped ones).
  final List<Map<String, Object?>> received = [];

  RawDatagramSocket? _socket;

  int get port => _socket!.port;

  /// Starts listening; returns the bound port. Use [port] 0 for a random one.
  Future<int> start({InternetAddress? address, int port = 0}) async {
    final socket = await RawDatagramSocket.bind(address ?? InternetAddress.loopbackIPv4, port);
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      Map<String, Object?> request;
      try {
        request = (jsonDecode(utf8.decode(datagram.data)) as Map).cast<String, Object?>();
      } catch (_) {
        return;
      }
      received.add(request);
      if (!responding) return;
      if (dropNext > 0) {
        dropNext--;
        return;
      }
      final reply = _handle(request);
      socket.send(utf8.encode(jsonEncode(reply)), datagram.address, datagram.port);
    });
    return socket.port;
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
  }

  Map<String, Object?> _handle(Map<String, Object?> request) {
    final method = request['method'] as String?;
    final params = (request['params'] as Map?)?.cast<String, Object?>() ?? const {};
    Map<String, Object?> ok(Map<String, Object?> result) =>
        {'method': method, 'env': 'pro', 'result': result};

    switch (method) {
      case 'getPilot':
        return ok({'mac': mac, 'rssi': -55, ...pilot});
      case 'setPilot':
        _applyPilot(params);
        _push();
        return ok({'success': true});
      case 'getSystemConfig':
        return ok({
          'mac': mac,
          'homeId': 0,
          'roomId': 0,
          'moduleName': moduleName,
          'fwVersion': firmware,
          'groupId': 0,
          'ping': 0,
        });
      case 'getModelConfig' when supportsModelConfig:
        return ok({'ps': 1, 'pwmFreq': 1000, 'cctRange': cctRange});
      case 'getUserConfig':
        return ok({'fadeIn': 0, 'fadeOut': 0, 'whiteRange': cctRange.sublist(1, 3)});
      case 'registration':
        if (params['register'] == true) {
          pushTarget = InternetAddress.tryParse('${params['phoneIp']}');
          registrations++;
        }
        return ok({'mac': mac, 'success': true});
      default:
        return {
          'method': method,
          'env': 'pro',
          'error': {'code': -32601, 'message': 'Method not found'},
        };
    }
  }

  /// Simulates a change made outside Diz (wall switch, WiZ app, remote).
  void changeExternally(Map<String, Object?> params) {
    _applyPilot(params);
    _push();
  }

  /// Simulates the announcement a bulb sends after booting.
  void sendFirstBeat() =>
      _sendToTarget({'method': 'firstBeat', 'env': 'pro', 'params': {'mac': mac, 'fwVersion': firmware}});

  void _push() => _sendToTarget({
        'method': 'syncPilot',
        'env': 'pro',
        'params': {'mac': mac, 'rssi': -55, 'src': 'udp', ...pilot},
      });

  void _sendToTarget(Map<String, Object?> message) {
    final target = pushTarget;
    final socket = _socket;
    if (target == null || socket == null || !responding) return;
    socket.send(utf8.encode(jsonEncode(message)), target, pushPort);
  }

  void _applyPilot(Map<String, Object?> params) {
    if (params.containsKey('r') || params.containsKey('g') || params.containsKey('b')) {
      pilot
        ..remove('temp')
        ..['sceneId'] = 0
        ..['r'] = params['r'] ?? 0
        ..['g'] = params['g'] ?? 0
        ..['b'] = params['b'] ?? 0
        ..['c'] = 0
        ..['w'] = 0;
    }
    if (params.containsKey('temp')) {
      pilot
        ..removeWhere((k, _) => const {'r', 'g', 'b', 'c', 'w'}.contains(k))
        ..['sceneId'] = 0
        ..['temp'] = params['temp'];
    }
    if (params.containsKey('sceneId')) {
      pilot
        ..removeWhere((k, _) => const {'r', 'g', 'b', 'c', 'w', 'temp'}.contains(k))
        ..['sceneId'] = params['sceneId'];
    }
    if (params.containsKey('dimming')) pilot['dimming'] = params['dimming'];
    if (params.containsKey('state')) {
      pilot['state'] = params['state'];
    } else if (params.isNotEmpty) {
      // Real bulbs turn on when their look is changed.
      pilot['state'] = true;
    }
  }
}
