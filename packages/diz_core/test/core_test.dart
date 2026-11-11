import 'package:diz_core/diz_core.dart';
import 'package:test/test.dart';

void main() {
  group('SetStateCommand', () {
    test('normalized: off wins over everything else', () {
      const cmd = SetStateCommand(on: false, brightness: 50, kelvin: 3000);
      expect(cmd.normalized(), const SetStateCommand(on: false));
    });

    test('normalized: changing the look implies on and clamps brightness', () {
      expect(const SetStateCommand(brightness: 3).normalized(),
          const SetStateCommand(on: true, brightness: minBrightness));
      expect(const SetStateCommand(kelvin: 2700).normalized(),
          const SetStateCommand(on: true, kelvin: 2700));
    });

    test('validate', () {
      expect(const SetStateCommand().validate(), isNotNull);
      expect(const SetStateCommand(rgb: Rgb(1, 2, 3), kelvin: 3000).validate(), isNotNull);
      expect(const SetStateCommand(rgb: Rgb(0, 0, 0)).validate(), isNotNull);
      expect(const SetStateCommand(rgb: Rgb(256, 0, 0)).validate(), isNotNull);
      expect(const SetStateCommand(kelvin: 500).validate(), isNotNull);
      expect(const SetStateCommand(brightness: 101).validate(), isNotNull);
      expect(const SetStateCommand(on: true, brightness: 40, rgb: Rgb(255, 0, 0)).validate(), isNull);
    });

    test('mergedWith: newer fields win, color kinds replace each other', () {
      const a = SetStateCommand(brightness: 30, kelvin: 3000);
      expect(a.mergedWith(const SetStateCommand(rgb: Rgb(255, 0, 0))),
          const SetStateCommand(on: true, brightness: 30, rgb: Rgb(255, 0, 0)));
      expect(a.mergedWith(const SetStateCommand(brightness: 80)),
          const SetStateCommand(on: true, brightness: 80, kelvin: 3000));
    });

    test('mergedWith: off then brightness turns back on; brightness then off stays off', () {
      expect(const SetStateCommand(on: false).mergedWith(const SetStateCommand(brightness: 60)),
          const SetStateCommand(on: true, brightness: 60));
      expect(const SetStateCommand(brightness: 60).mergedWith(const SetStateCommand(on: false)),
          const SetStateCommand(on: false));
      expect(const SetStateCommand(on: false).mergedWith(const SetStateCommand(on: true)),
          const SetStateCommand(on: true));
    });

    test('forCapabilities drops unsupported parts and clamps kelvin', () {
      final tw = Capabilities.fromModuleName('ESP56_SHTW3_01');
      expect(const SetStateCommand(rgb: Rgb(255, 0, 0), brightness: 50).forCapabilities(tw),
          const SetStateCommand(brightness: 50));
      expect(const SetStateCommand(kelvin: 2200).forCapabilities(tw),
          const SetStateCommand(kelvin: 2700));
      final plug = Capabilities.fromModuleName('ESP10_SOCKET_06');
      expect(const SetStateCommand(on: true, brightness: 50).forCapabilities(plug),
          const SetStateCommand(on: true));
    });

    test('json round trip and type errors', () {
      const cmd = SetStateCommand(on: true, brightness: 42, rgb: Rgb(10, 20, 30));
      expect(SetStateCommand.fromJson(cmd.toJson()), cmd);
      expect(() => SetStateCommand.fromJson({'on': 'yes'}), throwsFormatException);
      expect(() => SetStateCommand.fromJson({'rgb': 'red'}), throwsFormatException);
    });
  });

  group('Capabilities', () {
    test('from module names', () {
      final rgb = Capabilities.fromModuleName('ESP01_SHRGB1C_31');
      expect(rgb.color && rgb.tunableWhite && rgb.dimmable, isTrue);
      expect(rgb.kelvinMin, 2200);
      final tw = Capabilities.fromModuleName('ESP56_SHTW3_01');
      expect(tw.color, isFalse);
      expect(tw.tunableWhite, isTrue);
      final dw = Capabilities.fromModuleName('ESP06_SHDW9_01');
      expect(dw.tunableWhite || dw.color, isFalse);
      expect(dw.dimmable, isTrue);
      expect(Capabilities.fromModuleName(null), Capabilities.fullColor);
      expect(Capabilities.fromModuleName('ESP01_SHRGB1C_31', kelvinMin: 2000).kelvinMin, 2000);
    });

    test('union', () {
      final tw = Capabilities.fromModuleName('ESP56_SHTW3_01');
      final dw = Capabilities.fromModuleName('ESP06_SHDW9_01');
      final u = Capabilities.none.union(tw).union(dw);
      expect(u.tunableWhite, isTrue);
      expect(u.color, isFalse);
      expect(u.kelvinMin, 2200); // DW keeps the default range; harmless as it has no white control
    });
  });

  group('LightState', () {
    test('applying switches modes', () {
      const s = LightState(on: false, brightness: 50, mode: ColorMode.scene, sceneId: 5);
      final white = s.applying(const SetStateCommand(kelvin: 3000));
      expect(white.on, isTrue);
      expect(white.mode, ColorMode.white);
      expect(white.sceneId, isNull);
      final red = white.applying(const SetStateCommand(rgb: Rgb(255, 0, 0)));
      expect(red.mode, ColorMode.rgb);
      expect(red.kelvin, isNull);
      expect(red.applying(const SetStateCommand(on: false)).on, isFalse);
    });

    test('light json round trip', () {
      const light = Light(
        id: 'a8bb50000001',
        name: 'Desk',
        online: true,
        capabilities: Capabilities.fullColor,
        ip: '192.168.1.50',
        state: LightState(on: true, brightness: 70, mode: ColorMode.rgb, rgb: Rgb(1, 2, 3)),
      );
      final back = Light.fromJson(light.toJson());
      expect(back.toJson(), light.toJson());
    });
  });

  test('kelvinToRgb is warm at 2200 K and near white at 6500 K', () {
    final warm = kelvinToRgb(2200);
    expect(warm.r, 255);
    expect(warm.b, lessThan(100));
    final cool = kelvinToRgb(6500);
    expect(cool.r, greaterThan(240));
    expect(cool.b, greaterThan(240));
  });
}
