import 'dart:convert';
import 'dart:io';

import 'package:diz_bridge/diz_bridge.dart';
import 'package:diz_bridge/src/testing/fake_bulb.dart';
import 'package:diz_core/diz_core.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// End-to-end: fake bulbs on loopback UDP <- Registry <- HTTP API <- http client.
void main() {
  late FakeBulb color;
  late FakeBulb white;
  late Directory stateDir;
  late Registry registry;
  late HttpServer server;
  late Uri base;

  Registry newRegistry({WizEndpoint? broadcast, List<WizEndpoint>? staticBulbs}) => Registry(
        transport: UdpWizTransport(),
        stateFile: '${stateDir.path}/lights.json',
        staticBulbs: staticBulbs ??
            [
              WizEndpoint(InternetAddress.loopbackIPv4, color.port),
              WizEndpoint(InternetAddress.loopbackIPv4, white.port),
            ],
        broadcast: broadcast,
        commandTimeout: const Duration(milliseconds: 60),
        readTimeout: const Duration(milliseconds: 60),
        discoveryListen: const Duration(milliseconds: 300),
      );

  Future<Map<String, Object?>> getJson(String path) async {
    final res = await http.get(base.resolve(path));
    return jsonDecode(res.body) as Map<String, Object?>;
  }

  Future<http.Response> send(String method, String path, Object body) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode(body);
    return http.Response.fromStream(await request.send());
  }

  setUp(() async {
    color = FakeBulb(mac: 'a8bb50000001', moduleName: 'ESP01_SHRGB1C_31');
    white = FakeBulb(
      mac: 'A8:BB:50:00:00:02',
      moduleName: 'ESP56_SHTW3_01',
      cctRange: const [2700, 2700, 6500, 6500],
      supportsModelConfig: false, // old firmware: range comes from getUserConfig
    );
    await color.start();
    await white.start();
    stateDir = await Directory.systemTemp.createTemp('diz_test');
    registry = newRegistry();
    await registry.load();
    await registry.discover();
    server = await shelf_io.serve(buildHandler(registry), InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
  });

  tearDown(() async {
    await server.close(force: true);
    await color.stop();
    await white.stop();
    await stateDir.delete(recursive: true);
  });

  test('health', () async {
    final health = BridgeHealth.fromJson(await getJson('api/health'));
    expect(health.apiVersion, dizApiVersion);
    expect(health.lightCount, 2);
    expect(health.isCompatible, isTrue);
  });

  test('lists lights with capabilities and live state', () async {
    final lights = lightsFromJson((await getJson('api/lights'))['lights']);
    expect(lights.map((l) => l.id), containsAll(['a8bb50000001', 'a8bb50000002']));
    final c = lights.firstWhere((l) => l.id == 'a8bb50000001');
    final w = lights.firstWhere((l) => l.id == 'a8bb50000002');
    expect(c.online, isTrue);
    expect(c.capabilities.color, isTrue);
    expect(c.capabilities.kelvinMin, 2200);
    expect(w.capabilities.color, isFalse);
    expect(w.capabilities.kelvinMin, 2700);
    expect(c.state, const LightState(on: true, brightness: 80, mode: ColorMode.white, kelvin: 2700));
    expect(c.rssi, -55);
  });

  test('sets color on one light', () async {
    final res = await send('POST', 'api/lights/a8bb50000001/state', {
      'brightness': 40,
      'rgb': {'r': 255, 'g': 0, 'b': 128},
    });
    expect(res.statusCode, 200, reason: res.body);
    final light = Light.fromJson((jsonDecode(res.body) as Map)['light'] as Map<String, Object?>);
    expect(light.state!.mode, ColorMode.rgb);
    expect(light.state!.rgb, const Rgb(255, 0, 128));
    expect(color.pilot, containsPair('r', 255));
    expect(color.pilot, containsPair('dimming', 40));
    expect(color.pilot.containsKey('temp'), isFalse);
  });

  test('group command adapts to each bulb', () async {
    var res = await send('POST', 'api/group/state', {'kelvin': 2200, 'brightness': 30});
    expect(res.statusCode, 200, reason: res.body);
    expect(color.pilot['temp'], 2200);
    expect(white.pilot['temp'], 2700, reason: 'clamped to the TW bulb range');

    res = await send('POST', 'api/group/state', {'rgb': {'r': 0, 'g': 0, 'b': 255}});
    expect(res.statusCode, 200);
    expect(color.pilot['b'], 255);
    expect(white.pilot.containsKey('b'), isFalse, reason: 'white-only bulb skips color');

    res = await send('POST', 'api/group/state', {'on': false});
    expect(GroupResult.fromJson(jsonDecode(res.body) as Map<String, Object?>).failed, isEmpty);
    expect(color.pilot['state'], isFalse);
    expect(white.pilot['state'], isFalse);
  });

  test('retries lost packets', () async {
    color.dropNext = 2;
    final res = await send('POST', 'api/lights/a8bb50000001/state', {'on': false});
    expect(res.statusCode, 200, reason: res.body);
    expect(color.pilot['state'], isFalse);
  });

  test('offline bulbs are flagged, fail single commands and are skipped by the group', () async {
    white.responding = false;
    final lights = lightsFromJson((await getJson('api/lights'))['lights']);
    expect(lights.firstWhere((l) => l.id == 'a8bb50000002').online, isFalse);

    final single = await send('POST', 'api/lights/a8bb50000002/state', {'on': true});
    expect(single.statusCode, 504);

    final group = await send('POST', 'api/group/state', {'on': true});
    expect(GroupResult.fromJson(jsonDecode(group.body) as Map<String, Object?>).failed, isEmpty);

    white.responding = true;
    final back = lightsFromJson((await getJson('api/lights'))['lights']);
    expect(back.firstWhere((l) => l.id == 'a8bb50000002').online, isTrue);
  });

  test('rename persists across restarts', () async {
    final res = await send('PATCH', 'api/lights/A8:BB:50:00:00:01', {'name': '  Desk lamp '});
    expect(res.statusCode, 200, reason: res.body);
    final restarted = newRegistry(staticBulbs: const []);
    await restarted.load();
    expect(restarted.byId('a8bb50000001')!.name, 'Desk lamp');
    expect(restarted.byId('a8bb50000001')!.model, 'ESP01_SHRGB1C_31');
  });

  test('discovers via broadcast probe', () async {
    final fresh = newRegistry(
      broadcast: WizEndpoint(InternetAddress.loopbackIPv4, color.port),
      staticBulbs: const [],
    );
    expect(await fresh.discover(), 1);
    expect(fresh.byId('a8bb50000001')!.capabilities.color, isTrue);
  });

  test('rejects bad requests', () async {
    expect((await send('POST', 'api/lights/a8bb50000001/state', {'brightness': 'max'})).statusCode, 400);
    expect((await send('POST', 'api/lights/a8bb50000001/state', <String, Object?>{})).statusCode, 400);
    expect((await send('POST', 'api/lights/a8bb50000001/state', {'rgb': {'r': 0, 'g': 0, 'b': 0}})).statusCode,
        400);
    expect((await send('POST', 'api/lights/ffffffffffff/state', {'on': true})).statusCode, 404);
    expect((await send('PATCH', 'api/lights/a8bb50000001', {'name': ''})).statusCode, 400);
    expect((await http.get(base.resolve('api/nope'))).statusCode, 404);
    final root = await http.get(base);
    expect(root.statusCode, 200);
    expect(root.body, contains('diz-bridge'));
  });
}
