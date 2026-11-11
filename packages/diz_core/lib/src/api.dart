import 'light.dart';

/// Version of the HTTP API between app and bridge. Bump on breaking changes;
/// the app shows an "update the bridge/app" message on mismatch.
const int dizApiVersion = 1;

/// Default TCP port of the bridge.
const int defaultBridgePort = 8787;

/// Response of `GET /api/health`.
class BridgeHealth {
  const BridgeHealth({
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.lightCount,
  });

  final String name;
  final String version;
  final int apiVersion;
  final int lightCount;

  bool get isCompatible => apiVersion == dizApiVersion;

  factory BridgeHealth.fromJson(Map<String, Object?> json) => BridgeHealth(
        name: json['name'] as String? ?? 'unknown',
        version: json['version'] as String? ?? 'unknown',
        apiVersion: (json['apiVersion'] as num?)?.toInt() ?? 0,
        lightCount: (json['lightCount'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'version': version,
        'apiVersion': apiVersion,
        'lightCount': lightCount,
      };
}

/// Response of `POST /api/group/state`.
class GroupResult {
  const GroupResult({required this.lights, required this.failed});

  /// All lights after the command, including those that failed.
  final List<Light> lights;

  /// IDs of lights that did not acknowledge the command.
  final List<String> failed;

  factory GroupResult.fromJson(Map<String, Object?> json) => GroupResult(
        lights: lightsFromJson(json['lights']),
        failed: (json['failed'] as List? ?? const []).cast<String>(),
      );

  Map<String, Object?> toJson() => {
        'lights': [for (final l in lights) l.toJson()],
        'failed': failed,
      };
}

List<Light> lightsFromJson(Object? json) => [
      for (final item in (json as List? ?? const []))
        Light.fromJson((item as Map).cast<String, Object?>()),
    ];
