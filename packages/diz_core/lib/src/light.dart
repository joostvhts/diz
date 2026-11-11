import 'commands.dart';

/// Brightness limits accepted by WiZ bulbs, in percent.
const int minBrightness = 10;
const int maxBrightness = 100;

/// What a light is currently showing.
enum ColorMode {
  /// Tunable white, described by [LightState.kelvin].
  white,

  /// RGB color, described by [LightState.rgb].
  rgb,

  /// A built-in WiZ scene (Fireplace, Ocean, ...), described by [LightState.sceneId].
  scene,

  /// Not reported or not understood.
  unknown;

  static ColorMode fromName(String? name) =>
      ColorMode.values.firstWhere((m) => m.name == name, orElse: () => ColorMode.unknown);
}

/// An RGB color with 0-255 channels.
class Rgb {
  const Rgb(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;

  factory Rgb.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('rgb must be an object {r, g, b}');
    int channel(String key) {
      final v = json[key];
      if (v is! num) throw FormatException('rgb.$key must be a number');
      return v.round();
    }

    return Rgb(channel('r'), channel('g'), channel('b'));
  }

  Map<String, int> toJson() => {'r': r, 'g': g, 'b': b};

  bool get isValid => [r, g, b].every((c) => c >= 0 && c <= 255);
  bool get isBlack => r == 0 && g == 0 && b == 0;

  String toHex() => '#${[r, g, b].map((c) => c.toRadixString(16).padLeft(2, '0')).join()}';

  @override
  bool operator ==(Object other) => other is Rgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'Rgb($r, $g, $b)';
}

/// What a light can do. Derived from the WiZ module name and, when available,
/// the color temperature range the bulb reports itself.
class Capabilities {
  const Capabilities({
    required this.dimmable,
    required this.color,
    required this.tunableWhite,
    this.kelvinMin = 2200,
    this.kelvinMax = 6500,
  });

  /// Full color + tunable white bulb. Used when the model is unknown,
  /// because it is by far the most common WiZ bulb.
  static const Capabilities fullColor =
      Capabilities(dimmable: true, color: true, tunableWhite: true);

  /// Nothing supported (empty group).
  static const Capabilities none =
      Capabilities(dimmable: false, color: false, tunableWhite: false);

  final bool dimmable;
  final bool color;
  final bool tunableWhite;
  final int kelvinMin;
  final int kelvinMax;

  /// Maps WiZ module names such as `ESP01_SHRGB1C_31` (color),
  /// `ESP56_SHTW3_01` (tunable white), `ESP06_SHDW9_01` (dimmable white) or
  /// `ESP10_SOCKET_06` (smart plug) to capabilities.
  factory Capabilities.fromModuleName(String? moduleName, {int? kelvinMin, int? kelvinMax}) {
    final name = (moduleName ?? '').toUpperCase();
    Capabilities base;
    if (name.contains('SOCKET')) {
      base = const Capabilities(dimmable: false, color: false, tunableWhite: false);
    } else if (name.contains('RGB')) {
      base = fullColor;
    } else if (name.contains('TW')) {
      base = const Capabilities(dimmable: true, color: false, tunableWhite: true, kelvinMin: 2700);
    } else if (name.contains('DW')) {
      base = const Capabilities(dimmable: true, color: false, tunableWhite: false);
    } else {
      base = fullColor;
    }
    return Capabilities(
      dimmable: base.dimmable,
      color: base.color,
      tunableWhite: base.tunableWhite,
      kelvinMin: kelvinMin ?? base.kelvinMin,
      kelvinMax: kelvinMax ?? base.kelvinMax,
    );
  }

  factory Capabilities.fromJson(Map<String, Object?> json) => Capabilities(
        dimmable: json['dimmable'] as bool? ?? true,
        color: json['color'] as bool? ?? false,
        tunableWhite: json['tunableWhite'] as bool? ?? false,
        kelvinMin: (json['kelvinMin'] as num?)?.toInt() ?? 2200,
        kelvinMax: (json['kelvinMax'] as num?)?.toInt() ?? 6500,
      );

  Map<String, Object?> toJson() => {
        'dimmable': dimmable,
        'color': color,
        'tunableWhite': tunableWhite,
        'kelvinMin': kelvinMin,
        'kelvinMax': kelvinMax,
      };

  /// Everything that at least one of the two supports (used for group controls).
  Capabilities union(Capabilities other) {
    if (identical(this, none)) return other;
    if (identical(other, none)) return this;
    return Capabilities(
      dimmable: dimmable || other.dimmable,
      color: color || other.color,
      tunableWhite: tunableWhite || other.tunableWhite,
      kelvinMin: kelvinMin < other.kelvinMin ? kelvinMin : other.kelvinMin,
      kelvinMax: kelvinMax > other.kelvinMax ? kelvinMax : other.kelvinMax,
    );
  }

  int clampKelvin(int kelvin) => kelvin.clamp(kelvinMin, kelvinMax);

  @override
  bool operator ==(Object other) =>
      other is Capabilities &&
      other.dimmable == dimmable &&
      other.color == color &&
      other.tunableWhite == tunableWhite &&
      other.kelvinMin == kelvinMin &&
      other.kelvinMax == kelvinMax;

  @override
  int get hashCode => Object.hash(dimmable, color, tunableWhite, kelvinMin, kelvinMax);
}

/// The visible state of one light.
class LightState {
  const LightState({
    required this.on,
    required this.brightness,
    this.mode = ColorMode.unknown,
    this.rgb,
    this.kelvin,
    this.sceneId,
  });

  final bool on;

  /// Percent, [minBrightness]..[maxBrightness].
  final int brightness;
  final ColorMode mode;
  final Rgb? rgb;
  final int? kelvin;
  final int? sceneId;

  /// Returns the state this light will have after [command] is applied.
  /// Used for optimistic UI updates and to update the bridge cache after a
  /// bulb acknowledged a command.
  LightState applying(SetStateCommand command) {
    final c = command.normalized();
    var mode = this.mode;
    var rgb = this.rgb;
    var kelvin = this.kelvin;
    var sceneId = this.sceneId;
    if (c.rgb != null) {
      mode = ColorMode.rgb;
      rgb = c.rgb;
      kelvin = null;
      sceneId = null;
    } else if (c.kelvin != null) {
      mode = ColorMode.white;
      kelvin = c.kelvin;
      rgb = null;
      sceneId = null;
    }
    return LightState(
      on: c.on ?? on,
      brightness: c.brightness ?? brightness,
      mode: mode,
      rgb: rgb,
      kelvin: kelvin,
      sceneId: sceneId,
    );
  }

  factory LightState.fromJson(Map<String, Object?> json) => LightState(
        on: json['on'] as bool? ?? false,
        brightness: (json['brightness'] as num?)?.toInt() ?? maxBrightness,
        mode: ColorMode.fromName(json['mode'] as String?),
        rgb: json['rgb'] == null ? null : Rgb.fromJson(json['rgb']),
        kelvin: (json['kelvin'] as num?)?.toInt(),
        sceneId: (json['sceneId'] as num?)?.toInt(),
      );

  Map<String, Object?> toJson() => {
        'on': on,
        'brightness': brightness,
        'mode': mode.name,
        if (rgb != null) 'rgb': rgb!.toJson(),
        if (kelvin != null) 'kelvin': kelvin,
        if (sceneId != null) 'sceneId': sceneId,
      };

  @override
  bool operator ==(Object other) =>
      other is LightState &&
      other.on == on &&
      other.brightness == brightness &&
      other.mode == mode &&
      other.rgb == rgb &&
      other.kelvin == kelvin &&
      other.sceneId == sceneId;

  @override
  int get hashCode => Object.hash(on, brightness, mode, rgb, kelvin, sceneId);

  @override
  String toString() => 'LightState(${toJson()})';
}

/// A light as exposed by the bridge API.
class Light {
  const Light({
    required this.id,
    required this.name,
    required this.online,
    required this.capabilities,
    this.ip,
    this.model,
    this.firmware,
    this.state,
    this.rssi,
  });

  /// The bulb's MAC address, lowercase hex without separators. Stable across IP changes.
  final String id;
  final String name;
  final bool online;
  final Capabilities capabilities;
  final String? ip;

  /// WiZ module name, e.g. `ESP01_SHRGB1C_31`.
  final String? model;
  final String? firmware;

  /// Last known state; null if the bulb has never answered.
  final LightState? state;

  /// Wi-Fi signal strength in dBm.
  final int? rssi;

  bool get isOn => online && (state?.on ?? false);

  Light copyWith({String? name, bool? online, LightState? state}) => Light(
        id: id,
        name: name ?? this.name,
        online: online ?? this.online,
        capabilities: capabilities,
        ip: ip,
        model: model,
        firmware: firmware,
        state: state ?? this.state,
        rssi: rssi,
      );

  factory Light.fromJson(Map<String, Object?> json) => Light(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['id'] as String,
        online: json['online'] as bool? ?? false,
        capabilities: json['capabilities'] is Map
            ? Capabilities.fromJson((json['capabilities'] as Map).cast<String, Object?>())
            : Capabilities.fullColor,
        ip: json['ip'] as String?,
        model: json['model'] as String?,
        firmware: json['firmware'] as String?,
        state: json['state'] is Map
            ? LightState.fromJson((json['state'] as Map).cast<String, Object?>())
            : null,
        rssi: (json['rssi'] as num?)?.toInt(),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'online': online,
        'capabilities': capabilities.toJson(),
        if (ip != null) 'ip': ip,
        if (model != null) 'model': model,
        if (firmware != null) 'firmware': firmware,
        if (state != null) 'state': state!.toJson(),
        if (rssi != null) 'rssi': rssi,
      };
}
