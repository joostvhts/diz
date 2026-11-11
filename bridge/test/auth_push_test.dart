import 'dart:convert';
import 'dart:io';

import 'package:diz_bridge/diz_bridge.dart';
import 'package:diz_bridge/src/testing/fake_bulb.dart';
import 'package:diz_core/diz_core.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

Registry _registry(List<WizEndpoint> bulbs, {InternetAddress? advertise}) => Registry(
      transport: UdpWizTransport(),
      staticBulbs: bulbs,
      advertiseAddress: advertise,
      commandTimeout: const Duration(milliseconds: 60),
      readTimeout: const Duration(milliseconds: 60),
    );

/// Polls [condition] until it holds or one second passes.
Future<void> eventually(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 50 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue, reason: reason);
}

void main() {
  group('bearer token', () {
    const token = 'test-token-0123456789abcdef';
    late HttpServer server;
    late Uri base;

    setUp(() async {
      server = await shelf_io.serve(
          buildHandler(_registry(const []), apiToken: token), InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}/');
    });
    tearDown(() => server.close(force: true));

    test('/api requires the token', () async {
      final none = await http.get(base.resolve('api/lights'));
      expect(none.statusCode, 401);
      expect(none.headers['www-authenticate'], startsWith('Bearer'));

      final wrong = await http.get(base.resolve('api/lights'),
          headers: {'authorization': 'Bearer test-token-0123456789abcdeX'});
      expect(wrong.statusCode, 401);

      final basic = await http.get(base.resolve('api/lights'), headers: {'authorization': 'Basic $token'});
      expect(basic.statusCode, 401);

      final ok = await http.get(base.resolve('api/lights'), headers: {'authorization': 'bearer $token'});
      expect(ok.statusCode, 200);
    });

    test('/healthz is open and says nothing else', () async {
      final res = await http.get(base.resolve('healthz'));
      expect(res.statusCode, 200);
      expect(jsonDecode(res.body), {'status': 'ok'});
    });
  });

  group('config', () {
    test('token: unset, placeholder, too short, from file', () async {
      expect(BridgeConfig.readApiToken({}), isNull);
      expect(BridgeConfig.readApiToken({'DIZ_API_TOKEN': '  '}), isNull);
      expect(() => BridgeConfig.readApiToken({'DIZ_API_TOKEN': 'CHANGEME'}), throwsFormatException);
      expect(() => BridgeConfig.readApiToken({'DIZ_API_TOKEN': 'short'}), throwsFormatException);
      expect(BridgeConfig.readApiToken({'DIZ_API_TOKEN': ' 0123456789abcdef '}), '0123456789abcdef');

      final dir = await Directory.systemTemp.createTemp('diz_token');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/token')..writeAsStringSync('from-a-file-0123456789\n');
      expect(BridgeConfig.readApiToken({'DIZ_API_TOKEN_FILE': file.path, 'DIZ_API_TOKEN': 'ignored-0123456789'}),
          'from-a-file-0123456789');
    });

    test('advertise ip must be IPv4 and enables push', () {
      final env = {'DIZ_ADVERTISE_IP': '192.168.1.5', 'DIZ_BROADCAST': 'off'};
      final config = BridgeConfig.fromArgs(BridgeConfig.parser(env).parse([]), env);
      expect(config.advertise!.address, '192.168.1.5');
      expect(config.pushPort, wizPushPort);
      expect(config.broadcast, isNull);
      expect(config.toString(), isNot(contains('token=')));

      final bad = {'DIZ_ADVERTISE_IP': 'pi.local'};
      expect(() => BridgeConfig.fromArgs(BridgeConfig.parser(bad).parse([]), bad), throwsFormatException);
    });
  });

  group('push updates', () {
    late PushListener listener;
    late FakeBulb bulb;
    late Registry registry;

    setUp(() async {
      registry = _registry(const [], advertise: InternetAddress.loopbackIPv4); // replaced below
      listener = PushListener((message, from) => registry.handlePush(message, from));
      await listener.start(host: InternetAddress.loopbackIPv4, port: 0);
      bulb = FakeBulb(mac: 'a8bb50000009', pushPort: listener.port);
      await bulb.start();
      registry = _registry([WizEndpoint(InternetAddress.loopbackIPv4, bulb.port)],
          advertise: InternetAddress.loopbackIPv4);
      await registry.discover();
    });

    tearDown(() async {
      listener.close();
      await bulb.stop();
    });

    test('registration tells the bulb where to push, and pushes update the state', () async {
      await registry.registerPush();
      expect(bulb.registrations, 1);
      expect(bulb.pushTarget, InternetAddress.loopbackIPv4);

      bulb.changeExternally({'r': 255, 'g': 0, 'b': 0, 'dimming': 30});
      await eventually(() => registry.byId('a8bb50000009')!.state?.mode == ColorMode.rgb,
          reason: 'syncPilot should update the cached state');
      final state = registry.byId('a8bb50000009')!.state!;
      expect(state.rgb, const Rgb(255, 0, 0));
      expect(state.brightness, 30);
    });

    test('a bulb that rebooted is registered again', () async {
      await registry.registerPush();
      bulb.sendFirstBeat();
      await eventually(() => bulb.registrations == 2);
    });

    test('an unknown bulb announcing itself is added', () async {
      final stranger = FakeBulb(mac: 'a8bb5000000a', pushPort: listener.port);
      await stranger.start();
      addTearDown(stranger.stop);
      stranger.pushTarget = InternetAddress.loopbackIPv4;
      stranger.sendFirstBeat();
      await eventually(() => registry.count == 2);
    });

    test('without an advertise address nothing is registered', () async {
      final noPush = _registry([WizEndpoint(InternetAddress.loopbackIPv4, bulb.port)]);
      await noPush.discover();
      await noPush.registerPush();
      expect(noPush.pushEnabled, isFalse);
      expect(bulb.registrations, 0);
    });
  });
}
