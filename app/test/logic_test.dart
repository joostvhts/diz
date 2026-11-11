import 'dart:async';

import 'package:diz/src/api/bridge_client.dart';
import 'package:diz/src/settings.dart';
import 'package:diz/src/state/lights_controller.dart';
import 'package:diz/src/util/command_throttle.dart';
import 'package:diz_core/diz_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_api.dart';

void main() {
  group('parseBridgeUrl', () {
    test('defaults to https without a port, adds a trailing slash', () {
      expect(parseBridgeUrl('lights.example.com').toString(), 'https://lights.example.com/');
      expect(parseBridgeUrl(' 192.168.1.5:9000 ').toString(), 'https://192.168.1.5:9000/');
      expect(parseBridgeUrl('https://lights.example.com/').toString(), 'https://lights.example.com/');
    });

    test('explicit http talks to a bare bridge on its default port; sub-paths are kept', () {
      expect(parseBridgeUrl('http://192.168.1.5').toString(), 'http://192.168.1.5:8787/');
      expect(parseBridgeUrl('http://host:1234/diz').toString(), 'http://host:1234/diz/');
    });

    test('rejects nonsense', () {
      expect(parseBridgeUrl(''), isNull);
      expect(parseBridgeUrl('ftp://host'), isNull);
    });
  });

  group('CommandThrottle', () {
    test('sends the first command at once, merges the burst, and always sends the final value', () async {
      final sent = <SetStateCommand>[];
      final throttle = CommandThrottle(
        interval: const Duration(milliseconds: 40),
        send: (key, command) async => sent.add(command),
      );
      for (var b = 10; b <= 50; b += 10) {
        throttle.push('a', SetStateCommand(brightness: b));
      }
      expect(sent, [const SetStateCommand(brightness: 10)]);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(sent.last, const SetStateCommand(on: true, brightness: 50));
      expect(sent.length, 2);
      throttle.dispose();
    });

    test('never has two requests in flight for the same key', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final gate = Completer<void>();
      final throttle = CommandThrottle(
        interval: Duration.zero,
        send: (key, command) async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await gate.future;
          inFlight--;
        },
      );
      throttle.push('a', const SetStateCommand(on: true));
      throttle.push('a', const SetStateCommand(on: false));
      expect(throttle.isBusy('a'), isTrue);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(maxInFlight, 1);
      expect(throttle.isBusy('a'), isFalse);
      throttle.dispose();
    });
  });

  group('LightsController', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('group state averages lights that are on and ignores offline ones', () async {
      final api = FakeLightsApi([
        colorLight,
        whiteLight.copyWith(state: const LightState(on: true, brightness: 20, mode: ColorMode.white, kelvin: 4000)),
        offlineLight,
      ]);
      final controller = LightsController(api: api);
      await controller.refresh();
      expect(controller.groupState!.brightness, 40);
      expect(controller.groupState!.on, isTrue);
      expect(controller.groupCapabilities.color, isTrue);
      expect(controller.onlineLights.length, 2);
      controller.dispose();
    });

    test('optimistic updates survive a poll that still returns the old state', () async {
      // The fake bridge records commands but keeps reporting the old state.
      final api = FakeLightsApi([colorLight])..applyCommands = false;
      final controller = LightsController(api: api, throttleInterval: Duration.zero);
      await controller.refresh();

      controller.setLight(colorLight.id, const SetStateCommand(brightness: 90));
      expect(controller.light(colorLight.id)!.state!.brightness, 90);
      await Future<void>.delayed(Duration.zero);
      expect(api.commands.single, (colorLight.id, const SetStateCommand(brightness: 90)));

      await controller.refresh();
      expect(controller.light(colorLight.id)!.state!.brightness, 90, reason: 'within the grace period');
      controller.dispose();
    });

    test('polled state wins again after the grace period', () async {
      final api = FakeLightsApi([colorLight])..applyCommands = false;
      final controller =
          LightsController(api: api, throttleInterval: Duration.zero, localEditGrace: Duration.zero);
      await controller.refresh();
      controller.setLight(colorLight.id, const SetStateCommand(brightness: 90));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await controller.refresh();
      expect(controller.light(colorLight.id)!.state!.brightness, 60);
      controller.dispose();
    });

    test('reports an unreachable bridge', () async {
      final api = FakeLightsApi([colorLight])..failWith = const BridgeException('bridge down');
      final controller = LightsController(api: api);
      await controller.refresh();
      expect(controller.error, 'bridge down');
      expect(controller.loaded, isFalse);
      controller.dispose();
    });
  });
}
