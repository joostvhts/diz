import 'dart:async';
import 'dart:io';

import 'package:diz_bridge/diz_bridge.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> arguments) async {
  final env = Platform.environment;
  final parser = BridgeConfig.parser(env);
  final BridgeConfig config;
  try {
    final args = parser.parse(arguments);
    if (args.flag('help')) {
      stdout
        ..writeln('diz-bridge $bridgeVersion - local control for WiZ lights\n')
        ..writeln('Usage: diz-bridge [options]')
        ..writeln('       diz-bridge healthcheck    exit 0 if the bridge on --port answers\n')
        ..writeln(parser.usage)
        ..writeln('\nAuthentication: set DIZ_API_TOKEN (or DIZ_API_TOKEN_FILE) to require\n'
            '"Authorization: Bearer <token>" on /api. /healthz is always open.');
      return;
    }
    if (args.rest.isNotEmpty) {
      if (args.rest.single == 'healthcheck') {
        exitCode = await _healthcheck(int.tryParse(args.option('port')!) ?? 8787);
        return;
      }
      throw FormatException('Unknown argument: ${args.rest.join(' ')}');
    }
    config = BridgeConfig.fromArgs(args, env);
  } on FormatException catch (e) {
    // ArgParserException is a FormatException too.
    stderr.writeln('diz-bridge: ${e.message}\nRun with --help for usage.');
    exitCode = 64;
    return;
  }

  void log(String message) => stdout.writeln(message);

  log('diz-bridge $bridgeVersion starting ($config)');
  if (config.apiToken == null) {
    log('WARNING: DIZ_API_TOKEN is not set. Anyone who can reach port ${config.port} '
        'can control your lights.');
  }

  final registry = Registry(
    transport: UdpWizTransport(),
    stateFile: config.stateFile,
    staticBulbs: config.bulbs,
    broadcast: config.broadcast,
    advertiseAddress: config.advertise,
    log: log,
  );
  await registry.load();

  final handler = buildHandler(
    registry,
    apiToken: config.apiToken,
    webRoot: config.webRoot,
    devCors: config.devCors,
    logger: (message, isError) => isError ? stderr.writeln(message) : log(message),
  );

  final HttpServer server;
  try {
    server = await shelf_io.serve(handler, config.host, config.port);
  } on SocketException catch (e) {
    stderr.writeln('diz-bridge: cannot listen on ${config.host}:${config.port}: ${e.message}');
    exitCode = 1;
    return;
  }
  log('Listening on http://${server.address.address}:${server.port}');

  // Push updates: bulbs send state changes to <advertise-ip>:38900.
  PushListener? push;
  Timer? pushTimer;
  final advertise = config.advertise;
  if (advertise != null) {
    final listener = PushListener(registry.handlePush);
    try {
      await listener.start(port: config.pushPort);
      push = listener;
      log('Push updates on: lights send changes to ${advertise.address}:$wizPushPort '
          '(listening on UDP ${config.pushPort})');
      pushTimer = Timer.periodic(pushKeepAlive, (_) => registry.registerPush());
    } on SocketException catch (e) {
      log('Push updates off: cannot listen on UDP ${config.pushPort} (${e.message}); polling only');
    }
  } else {
    log('Push updates off (set DIZ_ADVERTISE_IP to enable); polling only');
  }

  Future<void> discover() async {
    try {
      await registry.discover();
      if (push != null) await registry.registerPush();
    } catch (e) {
      log('Discovery failed: $e');
    }
  }

  unawaited(discover());
  final discoveryTimer = Timer.periodic(config.discoveryInterval, (_) => discover());

  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    log('Received $signal, shutting down');
    discoveryTimer.cancel();
    pushTimer?.cancel();
    push?.close();
    await server.close(force: true);
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}

/// For Docker's HEALTHCHECK: the image has no shell or curl.
Future<int> _healthcheck(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/healthz'));
    final response = await request.close().timeout(const Duration(seconds: 3));
    await response.drain<void>();
    return response.statusCode == 200 ? 0 : 1;
  } catch (e) {
    stderr.writeln('healthcheck failed: $e');
    return 1;
  } finally {
    client.close(force: true);
  }
}
