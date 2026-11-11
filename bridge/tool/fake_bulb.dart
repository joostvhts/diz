// Starts one or more simulated WiZ bulbs, for developing the bridge and app
// without real lights.
//
//   dart run tool/fake_bulb.dart --count 3
//
// then start the bridge with the printed --bulbs value. Use --host 0.0.0.0 to
// run them in a container.
import 'dart:io';

import 'package:args/args.dart';
import 'package:diz_bridge/src/testing/fake_bulb.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('count', defaultsTo: '3', help: 'Number of bulbs.')
    ..addOption('base-port', defaultsTo: '38901', help: 'Port of the first bulb.')
    ..addOption('host', defaultsTo: '127.0.0.1', help: 'Address to bind to.')
    ..addOption('push-port', defaultsTo: '38900', help: 'Port pushes are sent to (real bulbs: 38900).')
    ..addFlag('help', abbr: 'h', negatable: false);
  final args = parser.parse(arguments);
  if (args.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }
  final count = int.parse(args.option('count')!);
  final basePort = int.parse(args.option('base-port')!);
  final host = InternetAddress(args.option('host')!);
  final pushPort = int.parse(args.option('push-port')!);

  // A mix of models so the app's capability handling can be seen.
  const models = ['ESP01_SHRGB1C_31', 'ESP56_SHTW3_01', 'ESP01_SHRGB1C_31', 'ESP06_SHDW9_01'];
  final endpoints = <String>[];
  for (var i = 0; i < count; i++) {
    final bulb = FakeBulb(
      mac: 'fa4e00000${(i + 1).toRadixString(16).padLeft(3, '0')}',
      moduleName: models[i % models.length],
      pushPort: pushPort,
    );
    final port = await bulb.start(address: host, port: basePort + i);
    endpoints.add('${host.address}:$port');
    stdout.writeln('Fake bulb ${bulb.mac} (${bulb.moduleName}) on ${host.address}:$port');
  }
  stdout
    ..writeln()
    ..writeln('Start the bridge with:')
    ..writeln('  dart run bin/diz_bridge.dart --broadcast off --dev-cors --bulbs ${endpoints.join(',')}')
    ..writeln()
    ..writeln('Press Ctrl+C to stop.');
}
