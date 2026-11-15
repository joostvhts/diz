import 'dart:convert';
import 'dart:io';

import 'package:diz_core/diz_core.dart';
import 'package:diz_wiz/diz_wiz.dart';
import 'package:diz_wiz/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeBulb bulb;
  late WizEndpoint endpoint;

  Registry newRegistry(LightStore store) => Registry(
        transport: UdpWizTransport(),
        store: store,
        staticBulbs: [endpoint],
        commandTimeout: const Duration(milliseconds: 60),
        readTimeout: const Duration(milliseconds: 60),
      );

  setUp(() async {
    bulb = FakeBulb(mac: 'a8bb50000001', moduleName: 'ESP56_SHTW3_01');
    endpoint = WizEndpoint(InternetAddress.loopbackIPv4, await bulb.start());
  });

  tearDown(() => bulb.stop());

  test('saves what it learned to the store and loads it back', () async {
    final store = MemoryLightStore();
    final first = newRegistry(store);
    await first.load();
    expect(await first.discover(), 1);
    await first.rename('a8bb50000001', 'Desk');

    final saved = jsonDecode(store.json!) as Map<String, Object?>;
    expect(saved['version'], 1);
    expect((saved['lights'] as List).single, containsPair('name', 'Desk'));

    // A new registry on the same store knows the light before any discovery.
    final second = newRegistry(store);
    await second.load();
    final light = second.byId('a8bb50000001')!;
    expect(light.name, 'Desk');
    expect(light.model, 'ESP56_SHTW3_01');
    expect(light.capabilities.color, isFalse);
  });

  test('ignores an unreadable store and starts empty', () async {
    final registry = newRegistry(MemoryLightStore('{not json'));
    await registry.load();
    expect(registry.count, 0);
  });

  test('FileLightStore writes atomically and reads back', () async {
    final dir = await Directory.systemTemp.createTemp('diz_wiz_test');
    addTearDown(() => dir.delete(recursive: true));
    final store = FileLightStore('${dir.path}/sub/lights.json');
    expect(await store.read(), isNull);
    await store.write('{"version":1,"lights":[]}');
    expect(await store.read(), '{"version":1,"lights":[]}');
    expect(File('${dir.path}/sub/lights.json.tmp').existsSync(), isFalse);
  });

  test('works without a store', () async {
    final registry = Registry(transport: UdpWizTransport(), staticBulbs: [endpoint]);
    await registry.load();
    await registry.discover();
    await registry.rename('a8bb50000001', 'Hall');
    expect(registry.lights.single.name, 'Hall');
    expect(registry.lights.single.state, isNull); // not read yet
    await registry.refresh();
    expect(registry.lights.single.state?.on, isTrue);
    expect(registry.lights.single.state?.mode, ColorMode.white);
  });
}
