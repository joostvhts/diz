import 'dart:io';

import 'package:args/args.dart';
import 'package:diz_core/diz_core.dart';

import 'wiz/wiz_protocol.dart';
import 'wiz/wiz_transport.dart';

/// Bridge settings. Every option can be given as a flag or as an environment
/// variable (flags win), so the same binary works under systemd
/// (`EnvironmentFile=`), in Docker (`environment:` / `.env`) and by hand.
///
/// The API token is deliberately environment-only (`DIZ_API_TOKEN` or
/// `DIZ_API_TOKEN_FILE`) so it never shows up in the process list.
class BridgeConfig {
  const BridgeConfig({
    required this.host,
    required this.port,
    required this.stateDir,
    required this.broadcast,
    required this.bulbs,
    required this.advertise,
    required this.pushPort,
    required this.apiToken,
    required this.webRoot,
    required this.devCors,
    required this.discoveryInterval,
  });

  final String host;
  final int port;
  final String stateDir;

  /// Where discovery probes go; null disables broadcast discovery.
  final WizEndpoint? broadcast;

  /// Bulbs to probe directly, in addition to broadcast discovery.
  final List<WizEndpoint> bulbs;

  /// The host's LAN address that bulbs push status updates to; null disables push.
  final InternetAddress? advertise;

  /// UDP port to receive pushes on. Bulbs always send to [wizPushPort], so
  /// only change this behind a port mapping or in tests.
  final int pushPort;

  /// Bearer token required for `/api`; null means no authentication.
  final String? apiToken;
  final String? webRoot;
  final bool devCors;
  final Duration discoveryInterval;

  String get stateFile => '$stateDir${Platform.pathSeparator}lights.json';

  static ArgParser parser(Map<String, String> env) {
    // systemd sets STATE_DIRECTORY (possibly colon-separated) for StateDirectory=.
    final systemdState = env['STATE_DIRECTORY']?.split(':').first;
    return ArgParser()
      ..addOption('host',
          defaultsTo: env['DIZ_HOST'] ?? '0.0.0.0',
          help: 'Address the HTTP API listens on. [DIZ_HOST]')
      ..addOption('port',
          defaultsTo: env['DIZ_PORT'] ?? '$defaultBridgePort', help: 'HTTP port. [DIZ_PORT]')
      ..addOption('state-dir',
          defaultsTo: env['DIZ_STATE_DIR'] ?? systemdState ?? 'diz-state',
          help: 'Directory for lights.json (names, known bulbs). [DIZ_STATE_DIR]')
      ..addOption('broadcast',
          defaultsTo: env['DIZ_BROADCAST'] ?? '255.255.255.255',
          help: 'Discovery broadcast address (ip or ip:port), or "off". [DIZ_BROADCAST]')
      ..addOption('bulbs',
          defaultsTo: env['DIZ_BULBS'] ?? '',
          help: 'Comma-separated bulb addresses (ip or ip:port) to use in addition to '
              'discovery. [DIZ_BULBS]')
      ..addOption('advertise-ip',
          defaultsTo: env['DIZ_ADVERTISE_IP'] ?? '',
          help: "This host's LAN IPv4 address. Enables push status updates: bulbs are asked "
              'to send changes to this address on UDP $wizPushPort. [DIZ_ADVERTISE_IP]')
      ..addOption('push-port',
          defaultsTo: env['DIZ_PUSH_PORT'] ?? '$wizPushPort',
          help: 'UDP port to receive pushes on. Bulbs always send to $wizPushPort. [DIZ_PUSH_PORT]')
      ..addOption('web-root',
          defaultsTo: env['DIZ_WEB_ROOT'],
          help: 'Serve a web UI from this directory at /. [DIZ_WEB_ROOT]')
      ..addOption('discovery-interval',
          defaultsTo: env['DIZ_DISCOVERY_INTERVAL'] ?? '300',
          help: 'Seconds between automatic discovery runs. [DIZ_DISCOVERY_INTERVAL]')
      ..addFlag('dev-cors',
          defaultsTo: _truthy(env['DIZ_DEV_CORS']),
          negatable: false,
          help: 'Allow cross-origin requests (for UI development). [DIZ_DEV_CORS=1]')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');
  }

  /// Throws [FormatException] (or [ArgParserException]) on bad input.
  static BridgeConfig fromArgs(ArgResults args, Map<String, String> env) {
    final port = _port(args.option('port')!, 'port');
    final pushPort = _port(args.option('push-port')!, 'push-port');
    final interval = int.tryParse(args.option('discovery-interval')!);
    if (interval == null || interval < 10) {
      throw const FormatException('discovery-interval must be a number of seconds >= 10');
    }
    final broadcastText = args.option('broadcast')!.trim();
    final broadcast = (broadcastText.isEmpty || broadcastText == 'off')
        ? null
        : WizEndpoint.parse(broadcastText);
    final bulbs = [
      for (final part in args.option('bulbs')!.split(','))
        if (part.trim().isNotEmpty) WizEndpoint.parse(part),
    ];
    final advertiseText = args.option('advertise-ip')!.trim();
    InternetAddress? advertise;
    if (advertiseText.isNotEmpty) {
      advertise = InternetAddress.tryParse(advertiseText);
      if (advertise == null || advertise.type != InternetAddressType.IPv4) {
        throw FormatException('advertise-ip must be an IPv4 address, got "$advertiseText"');
      }
    }
    final webRoot = args.option('web-root');
    return BridgeConfig(
      host: args.option('host')!,
      port: port,
      stateDir: args.option('state-dir')!,
      broadcast: broadcast,
      bulbs: bulbs,
      advertise: advertise,
      pushPort: pushPort,
      apiToken: readApiToken(env),
      webRoot: (webRoot == null || webRoot.isEmpty) ? null : webRoot,
      devCors: args.flag('dev-cors'),
      discoveryInterval: Duration(seconds: interval),
    );
  }

  /// Reads `DIZ_API_TOKEN_FILE` (e.g. a Docker secret) or `DIZ_API_TOKEN`.
  /// Rejects the placeholder from the example files and tokens that are too short.
  static String? readApiToken(Map<String, String> env) {
    final file = env['DIZ_API_TOKEN_FILE'];
    String? token;
    if (file != null && file.trim().isNotEmpty) {
      try {
        token = File(file.trim()).readAsStringSync().trim();
      } on FileSystemException catch (e) {
        throw FormatException('Cannot read DIZ_API_TOKEN_FILE ${file.trim()}: ${e.message}');
      }
    } else {
      token = env['DIZ_API_TOKEN']?.trim();
    }
    if (token == null || token.isEmpty) return null;
    if (token.toUpperCase() == 'CHANGEME') {
      throw const FormatException(
          'DIZ_API_TOKEN is still the CHANGEME placeholder. Generate one with: openssl rand -hex 32');
    }
    if (token.length < 16) {
      throw const FormatException(
          'DIZ_API_TOKEN is too short; use at least 16 characters (e.g. openssl rand -hex 32)');
    }
    return token;
  }

  static int _port(String text, String name) {
    final port = int.tryParse(text);
    if (port == null || port <= 0 || port > 65535) throw FormatException('Invalid $name: $text');
    return port;
  }

  /// Safe to log: never includes the token.
  @override
  String toString() => 'host=$host port=$port stateDir=$stateDir '
      'broadcast=${broadcast ?? 'off'} bulbs=${bulbs.isEmpty ? '-' : bulbs.join(',')} '
      'push=${advertise == null ? 'off' : '${advertise!.address}:$wizPushPort (listening on $pushPort)'} '
      'auth=${apiToken == null ? 'off' : 'bearer token'} webRoot=${webRoot ?? '-'} '
      'devCors=$devCors discoveryInterval=${discoveryInterval.inSeconds}s';
}

bool _truthy(String? value) => const {'1', 'true', 'yes', 'on'}.contains(value?.toLowerCase());
