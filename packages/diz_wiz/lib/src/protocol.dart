/// Message builders and parsers for the WiZ local UDP protocol.
///
/// WiZ bulbs listen on UDP 38899 and speak JSON-RPC-like messages:
/// `{"method": "getPilot", "params": {}}` is answered with
/// `{"method": "getPilot", "env": "pro", "result": {...}}` or
/// `{"method": ..., "error": {"code": -32601, "message": "..."}}`.
library;

import 'package:diz_core/diz_core.dart';

/// UDP port WiZ bulbs listen on.
const int wizPort = 38899;

/// UDP port WiZ bulbs send push updates (`syncPilot`, `firstBeat`) to. Fixed
/// by the firmware: the registration message carries an IP but no port.
const int wizPushPort = 38900;

/// Bulbs forget a push registration after a while; renew it this often
/// (same interval as pywizlight / Home Assistant).
const Duration pushKeepAlive = Duration(seconds: 20);

/// Identifies Diz as a push subscriber. Any 12-hex-digit value works.
const String dizPhoneMac = 'd12d12000001';

abstract final class WizMessages {
  static Map<String, Object?> getPilot() => {'method': 'getPilot', 'params': <String, Object?>{}};

  static Map<String, Object?> setPilot(Map<String, Object?> params) =>
      {'method': 'setPilot', 'params': params};

  static Map<String, Object?> getSystemConfig() =>
      {'method': 'getSystemConfig', 'params': <String, Object?>{}};

  static Map<String, Object?> getModelConfig() =>
      {'method': 'getModelConfig', 'params': <String, Object?>{}};

  static Map<String, Object?> getUserConfig() =>
      {'method': 'getUserConfig', 'params': <String, Object?>{}};

  /// Subscribes to push updates: the bulb will send `syncPilot` messages to
  /// [phoneIp]:[wizPushPort] whenever its state changes. [phoneIp] must be an
  /// address the bulb can reach (the host's LAN IP, not a container IP).
  static Map<String, Object?> registerPush(String phoneIp) => {
        'method': 'registration',
        'params': {'phoneIp': phoneIp, 'register': true, 'phoneMac': dizPhoneMac},
      };

  /// Discovery probe. Every bulb that receives it (via broadcast) answers with
  /// its MAC. `register: false` means we don't subscribe to push updates.
  static Map<String, Object?> registration() => {
        'method': 'registration',
        'params': {
          'phoneMac': 'AAAAAAAAAAAA',
          'register': false,
          'phoneIp': '1.2.3.4',
          'id': '1',
        },
      };
}

/// Translates a Diz command into `setPilot` params. The command is normalized
/// first, so "off" never carries other fields and look changes imply "on".
Map<String, Object?> pilotParams(SetStateCommand command) {
  final c = command.normalized();
  final params = <String, Object?>{};
  if (c.on != null) params['state'] = c.on;
  if (c.on == false) return params;
  if (c.brightness != null) params['dimming'] = c.brightness;
  if (c.rgb != null) {
    params['r'] = c.rgb!.r;
    params['g'] = c.rgb!.g;
    params['b'] = c.rgb!.b;
  }
  if (c.kelvin != null) params['temp'] = c.kelvin;
  return params;
}

/// Result of a `getPilot` call.
typedef PilotReading = ({LightState state, int? rssi, String? mac});

PilotReading parsePilot(Map<String, Object?> result) {
  int? intOf(String key) => (result[key] as num?)?.round();

  final sceneId = intOf('sceneId');
  final temp = intOf('temp');
  final r = intOf('r');
  final g = intOf('g');
  final b = intOf('b');

  final scene = sceneId != null && sceneId > 0 ? sceneId : null;

  // The colour the bulb reports decides the mode. Some WiZ scenes are static
  // whites that report their colour too: the WiZ app's white presets come back
  // as {"sceneId": 11, "temp": 2700} (Warm white) or {"sceneId": 13,
  // "temp": 6500} (Cool white). Only scenes without colour data (Fireplace,
  // Ocean, ...) are ColorMode.scene. The scene ID is kept in every mode.
  final ColorMode mode;
  if (temp != null && temp > 0) {
    mode = ColorMode.white;
  } else if (r != null && g != null && b != null) {
    mode = ColorMode.rgb;
  } else if (scene != null) {
    mode = ColorMode.scene;
  } else {
    mode = ColorMode.unknown;
  }

  final state = LightState(
    on: result['state'] == true,
    brightness: (intOf('dimming') ?? maxBrightness).clamp(minBrightness, maxBrightness),
    mode: mode,
    rgb: mode == ColorMode.rgb ? Rgb(r!.clamp(0, 255), g!.clamp(0, 255), b!.clamp(0, 255)) : null,
    kelvin: mode == ColorMode.white ? temp : null,
    sceneId: scene,
  );
  return (state: state, rssi: intOf('rssi'), mac: result['mac'] as String?);
}

/// Bulb identity from `getSystemConfig`.
typedef SystemInfo = ({String? mac, String? moduleName, String? firmware});

SystemInfo parseSystemConfig(Map<String, Object?> result) => (
      mac: result['mac'] as String?,
      moduleName: result['moduleName'] as String?,
      firmware: result['fwVersion'] as String?,
    );

/// Extracts the supported color temperature range. Newer firmware reports
/// `cctRange` in `getModelConfig`; older firmware has `extRange` or
/// `whiteRange` in `getUserConfig`. Returns nulls when nothing usable is found.
({int? min, int? max}) parseKelvinRange({
  Map<String, Object?>? modelConfig,
  Map<String, Object?>? userConfig,
}) {
  final candidates = [
    modelConfig?['cctRange'],
    userConfig?['extRange'],
    userConfig?['whiteRange'],
  ];
  for (final candidate in candidates) {
    if (candidate is! List || candidate.isEmpty) continue;
    final values = candidate.whereType<num>().map((n) => n.round()).where((n) => n > 0).toList();
    if (values.length < 2) continue;
    values.sort();
    final min = values.first;
    final max = values.last;
    if (min >= SetStateCommand.kelvinLowerBound &&
        max <= SetStateCommand.kelvinUpperBound &&
        min < max) {
      return (min: min, max: max);
    }
  }
  return (min: null, max: null);
}

/// Normalizes a MAC address to lowercase hex without separators.
String normalizeMac(String mac) => mac.toLowerCase().replaceAll(RegExp('[^0-9a-f]'), '');
