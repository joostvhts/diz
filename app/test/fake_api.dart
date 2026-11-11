import 'package:diz/src/api/bridge_client.dart';
import 'package:diz/src/state/lights_controller.dart';
import 'package:diz_core/diz_core.dart';

/// In-memory bridge for widget and controller tests.
class FakeLightsApi implements LightsApi {
  FakeLightsApi(List<Light> lights) : _lights = [...lights];

  List<Light> _lights;

  /// Every command received, keyed by light id or [groupKey].
  final List<(String, SetStateCommand)> commands = [];

  /// When set, every call throws this.
  BridgeException? failWith;

  /// When false, commands are recorded but the reported state doesn't change
  /// (a bridge that hasn't caught up yet).
  bool applyCommands = true;

  @override
  Uri get baseUrl => Uri.parse('http://bridge.test:8787/');

  void _maybeFail() {
    if (failWith != null) throw failWith!;
  }

  @override
  Future<BridgeHealth> health() async {
    _maybeFail();
    return BridgeHealth(name: 'diz-bridge', version: 'test', apiVersion: dizApiVersion, lightCount: _lights.length);
  }

  @override
  Future<List<Light>> lights() async {
    _maybeFail();
    return _lights;
  }

  Light _apply(Light light, SetStateCommand command) {
    if (!applyCommands) return light;
    final adapted = command.forCapabilities(light.capabilities);
    return light.copyWith(
        state: (light.state ?? const LightState(on: false, brightness: 100)).applying(adapted));
  }

  @override
  Future<Light> setLight(String id, SetStateCommand command) async {
    _maybeFail();
    commands.add((id, command));
    _lights = [for (final l in _lights) l.id == id ? _apply(l, command) : l];
    return _lights.firstWhere((l) => l.id == id);
  }

  @override
  Future<GroupResult> setGroup(SetStateCommand command, {List<String>? ids}) async {
    _maybeFail();
    commands.add((groupKey, command));
    _lights = [for (final l in _lights) l.online ? _apply(l, command) : l];
    return GroupResult(lights: _lights, failed: const []);
  }

  @override
  Future<Light> rename(String id, String name) async {
    _maybeFail();
    _lights = [for (final l in _lights) l.id == id ? l.copyWith(name: name) : l];
    return _lights.firstWhere((l) => l.id == id);
  }

  @override
  Future<({int added, List<Light> lights})> discover() async {
    _maybeFail();
    return (added: 0, lights: _lights);
  }

  @override
  void close() {}
}

const colorLight = Light(
  id: 'a8bb50000001',
  name: 'Desk',
  online: true,
  capabilities: Capabilities.fullColor,
  state: LightState(on: true, brightness: 60, mode: ColorMode.white, kelvin: 2700),
);

final whiteLight = Light(
  id: 'a8bb50000002',
  name: 'Hallway',
  online: true,
  capabilities: Capabilities.fromModuleName('ESP56_SHTW3_01'),
  state: const LightState(on: false, brightness: 100, mode: ColorMode.white, kelvin: 4000),
);

const offlineLight = Light(
  id: 'a8bb50000003',
  name: 'Porch',
  online: false,
  capabilities: Capabilities.fullColor,
);
