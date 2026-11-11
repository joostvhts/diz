import 'light.dart';

/// A change to apply to one light or a group. Every field is optional;
/// only the fields that are set are changed.
///
/// [rgb] and [kelvin] are mutually exclusive: RGB switches the bulb to color
/// mode, Kelvin switches it to white mode.
class SetStateCommand {
  const SetStateCommand({this.on, this.brightness, this.rgb, this.kelvin});

  final bool? on;

  /// Percent, [minBrightness]..[maxBrightness].
  final int? brightness;
  final Rgb? rgb;
  final int? kelvin;

  /// Lowest and highest color temperature any WiZ bulb accepts; the bridge
  /// clamps further to each bulb's own range.
  static const int kelvinLowerBound = 1000;
  static const int kelvinUpperBound = 10000;

  /// Parses a command from a JSON body. Throws [FormatException] on wrong types.
  /// Unknown keys are ignored so newer apps can talk to older bridges.
  factory SetStateCommand.fromJson(Map<String, Object?> json) {
    final on = json['on'];
    if (on != null && on is! bool) throw const FormatException('on must be a boolean');
    final brightness = json['brightness'];
    if (brightness != null && brightness is! num) {
      throw const FormatException('brightness must be a number');
    }
    final kelvin = json['kelvin'];
    if (kelvin != null && kelvin is! num) throw const FormatException('kelvin must be a number');
    return SetStateCommand(
      on: on as bool?,
      brightness: (brightness as num?)?.round(),
      rgb: json['rgb'] == null ? null : Rgb.fromJson(json['rgb']),
      kelvin: (kelvin as num?)?.round(),
    );
  }

  Map<String, Object?> toJson() => {
        if (on != null) 'on': on,
        if (brightness != null) 'brightness': brightness,
        if (rgb != null) 'rgb': rgb!.toJson(),
        if (kelvin != null) 'kelvin': kelvin,
      };

  bool get isEmpty => on == null && brightness == null && rgb == null && kelvin == null;

  /// Returns a human-readable problem, or null if the command is valid.
  String? validate() {
    if (isEmpty) return 'command is empty';
    if (rgb != null && kelvin != null) return 'rgb and kelvin cannot be set together';
    if (brightness != null && (brightness! < 0 || brightness! > maxBrightness)) {
      return 'brightness must be between $minBrightness and $maxBrightness';
    }
    if (rgb != null && !rgb!.isValid) return 'rgb channels must be between 0 and 255';
    if (rgb != null && rgb!.isBlack) return 'rgb cannot be black; turn the light off instead';
    if (kelvin != null && (kelvin! < kelvinLowerBound || kelvin! > kelvinUpperBound)) {
      return 'kelvin must be between $kelvinLowerBound and $kelvinUpperBound';
    }
    return null;
  }

  /// Applies the Diz rules:
  /// * turning off ignores everything else (WiZ would turn the bulb on again);
  /// * changing brightness or color implies turning on;
  /// * brightness is clamped to what WiZ accepts.
  SetStateCommand normalized() {
    if (on == false) return const SetStateCommand(on: false);
    final changesLook = brightness != null || rgb != null || kelvin != null;
    return SetStateCommand(
      on: changesLook ? true : on,
      brightness: brightness?.clamp(minBrightness, maxBrightness),
      rgb: rgb,
      kelvin: kelvin,
    );
  }

  /// Combines this (older) command with a [newer] one; the newer one wins per
  /// field, and a newer color choice replaces an older one of the other kind.
  SetStateCommand mergedWith(SetStateCommand newer) {
    // Turning off wins over anything queued before it.
    if (newer.on == false) return newer;
    // An older "off" carries no look worth keeping.
    final olderIsOff = on == false;
    final newerChangesLook = newer.brightness != null || newer.rgb != null || newer.kelvin != null;
    final Rgb? rgb;
    final int? kelvin;
    if (newer.rgb != null) {
      rgb = newer.rgb;
      kelvin = null;
    } else if (newer.kelvin != null) {
      rgb = null;
      kelvin = newer.kelvin;
    } else {
      rgb = olderIsOff ? null : this.rgb;
      kelvin = olderIsOff ? null : this.kelvin;
    }
    return SetStateCommand(
      on: newer.on ?? (newerChangesLook ? true : on),
      brightness: newer.brightness ?? (olderIsOff ? null : brightness),
      rgb: rgb,
      kelvin: kelvin,
    );
  }

  /// Drops what a light can't do and clamps Kelvin to its range.
  SetStateCommand forCapabilities(Capabilities caps) => SetStateCommand(
        on: on,
        brightness: caps.dimmable ? brightness : null,
        rgb: caps.color ? rgb : null,
        kelvin: caps.tunableWhite && kelvin != null ? caps.clampKelvin(kelvin!) : null,
      );

  @override
  bool operator ==(Object other) =>
      other is SetStateCommand &&
      other.on == on &&
      other.brightness == brightness &&
      other.rgb == rgb &&
      other.kelvin == kelvin;

  @override
  int get hashCode => Object.hash(on, brightness, rgb, kelvin);

  @override
  String toString() => 'SetStateCommand(${toJson()})';
}
