import 'package:diz_bridge/diz_bridge.dart';
import 'package:diz_core/diz_core.dart';
import 'package:test/test.dart';

void main() {
  test('pilotParams maps commands to setPilot params', () {
    expect(pilotParams(const SetStateCommand(on: false, brightness: 50)), {'state': false});
    expect(pilotParams(const SetStateCommand(brightness: 40, kelvin: 3000)),
        {'state': true, 'dimming': 40, 'temp': 3000});
    expect(pilotParams(const SetStateCommand(rgb: Rgb(255, 10, 0))),
        {'state': true, 'r': 255, 'g': 10, 'b': 0});
    expect(pilotParams(const SetStateCommand(on: true)), {'state': true});
  });

  test('parsePilot recognises white, rgb and scene modes', () {
    final white = parsePilot({'mac': 'x', 'rssi': -60, 'state': true, 'sceneId': 0, 'temp': 2700, 'dimming': 55});
    expect(white.state, const LightState(on: true, brightness: 55, mode: ColorMode.white, kelvin: 2700));
    expect(white.rssi, -60);

    final rgb = parsePilot({'state': false, 'sceneId': 0, 'r': 255, 'g': 0, 'b': 10, 'c': 0, 'w': 0, 'dimming': 100});
    expect(rgb.state.mode, ColorMode.rgb);
    expect(rgb.state.rgb, const Rgb(255, 0, 10));
    expect(rgb.state.on, isFalse);

    final scene = parsePilot({'state': true, 'sceneId': 5, 'speed': 100, 'dimming': 3});
    expect(scene.state.mode, ColorMode.scene);
    expect(scene.state.sceneId, 5);
    expect(scene.state.brightness, minBrightness);
  });

  test('parseKelvinRange prefers cctRange and falls back to user config', () {
    expect(parseKelvinRange(modelConfig: {'cctRange': [2200, 2700, 6500, 6500]}), (min: 2200, max: 6500));
    expect(parseKelvinRange(userConfig: {'extRange': [2200, 6500], 'whiteRange': [2700, 6500]}),
        (min: 2200, max: 6500));
    expect(parseKelvinRange(userConfig: {'whiteRange': [2700, 6500]}), (min: 2700, max: 6500));
    expect(parseKelvinRange(modelConfig: {'cctRange': [0, 0]}), (min: null, max: null));
    expect(parseKelvinRange(), (min: null, max: null));
  });

  test('normalizeMac', () {
    expect(normalizeMac('A8:BB:50:12:34:56'), 'a8bb50123456');
    expect(normalizeMac('a8bb50123456'), 'a8bb50123456');
  });

  test('WizEndpoint.parse', () {
    expect(WizEndpoint.parse('192.168.1.5').port, wizPort);
    expect(WizEndpoint.parse('127.0.0.1:38901').port, 38901);
    expect(() => WizEndpoint.parse('bulb.local'), throwsFormatException);
    expect(() => WizEndpoint.parse('1.2.3.4:x'), throwsFormatException);
  });
}
