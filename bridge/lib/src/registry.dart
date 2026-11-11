import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:diz_core/diz_core.dart';

import 'command_queue.dart';
import 'wiz/wiz_protocol.dart';
import 'wiz/wiz_transport.dart';

typedef Log = void Function(String message);

class UnknownLightException implements Exception {
  const UnknownLightException(this.id);
  final String id;

  @override
  String toString() => 'Unknown light: $id';
}

/// Everything the bridge knows about one bulb.
class BulbRecord {
  BulbRecord({
    required this.mac,
    required this.name,
    this.endpoint,
    this.moduleName,
    this.firmware,
    this.kelvinMin,
    this.kelvinMax,
  });

  final String mac;
  String name;
  WizEndpoint? endpoint;
  String? moduleName;
  String? firmware;
  int? kelvinMin;
  int? kelvinMax;

  /// Whether model/firmware/Kelvin range have been read from the bulb.
  bool infoLoaded = false;
  bool online = false;
  LightState? state;
  int? rssi;
  DateTime? lastSeen;

  /// When the bulb last pushed its state to us (null if it never did).
  DateTime? lastPush;

  Capabilities get capabilities =>
      Capabilities.fromModuleName(moduleName, kelvinMin: kelvinMin, kelvinMax: kelvinMax);

  Light toLight() => Light(
        id: mac,
        name: name,
        online: online,
        capabilities: capabilities,
        ip: endpoint?.toString(),
        model: moduleName,
        firmware: firmware,
        state: state,
        rssi: rssi,
      );

  /// What survives a restart. Live state is re-read from the bulbs.
  Map<String, Object?> toJson() => {
        'mac': mac,
        'name': name,
        if (endpoint != null) 'ip': endpoint!.address.address,
        if (endpoint != null) 'port': endpoint!.port,
        if (moduleName != null) 'moduleName': moduleName,
        if (firmware != null) 'firmware': firmware,
        if (kelvinMin != null) 'kelvinMin': kelvinMin,
        if (kelvinMax != null) 'kelvinMax': kelvinMax,
      };

  static BulbRecord fromJson(Map<String, Object?> json) {
    final ip = json['ip'] as String?;
    final address = ip == null ? null : InternetAddress.tryParse(ip);
    final record = BulbRecord(
      mac: json['mac'] as String,
      name: json['name'] as String? ?? defaultName(json['mac'] as String),
      endpoint: address == null
          ? null
          : WizEndpoint(address, (json['port'] as num?)?.toInt() ?? wizPort),
      moduleName: json['moduleName'] as String?,
      firmware: json['firmware'] as String?,
      kelvinMin: (json['kelvinMin'] as num?)?.toInt(),
      kelvinMax: (json['kelvinMax'] as num?)?.toInt(),
    );
    record.infoLoaded = record.moduleName != null;
    return record;
  }

  static String defaultName(String mac) =>
      'Light ${mac.length >= 4 ? mac.substring(mac.length - 4).toUpperCase() : mac}';
}

/// Owns the set of known bulbs: discovery, persistence, state reads and commands.
class Registry {
  Registry({
    required WizTransport transport,
    String? stateFile,
    List<WizEndpoint> staticBulbs = const [],
    WizEndpoint? broadcast,
    InternetAddress? advertiseAddress,
    Log? log,
    this.commandAttempts = 3,
    this.commandTimeout = const Duration(milliseconds: 200),
    this.readAttempts = 2,
    this.readTimeout = const Duration(milliseconds: 200),
    this.discoveryListen = const Duration(seconds: 2),
    this.rediscoverAfter = const Duration(minutes: 1),
  })  : _transport = transport,
        _stateFile = stateFile,
        _staticBulbs = staticBulbs,
        _broadcast = broadcast,
        _advertise = advertiseAddress,
        _log = log ?? ((_) {});

  final WizTransport _transport;
  final String? _stateFile;
  final List<WizEndpoint> _staticBulbs;
  final WizEndpoint? _broadcast;

  /// The address bulbs should push status updates to (the host's LAN IP).
  /// Null disables push registration.
  final InternetAddress? _advertise;
  final Log _log;

  final int commandAttempts;
  final Duration commandTimeout;
  final int readAttempts;
  final Duration readTimeout;
  final Duration discoveryListen;

  /// When a refresh finds an offline bulb and the last discovery is older than
  /// this, a background discovery runs (the bulb may have a new IP).
  final Duration rediscoverAfter;

  final Map<String, BulbRecord> _bulbs = {};
  late final CoalescingQueue _queue = CoalescingQueue(_send);
  Future<List<Light>>? _refreshing;
  Future<int>? _discovering;
  DateTime? _lastDiscovery;

  List<Light> get lights {
    final records = _bulbs.values.toList()
      ..sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.mac.compareTo(b.mac);
      });
    return [for (final r in records) r.toLight()];
  }

  int get count => _bulbs.length;

  Light? byId(String id) => _bulbs[normalizeMac(id)]?.toLight();

  // ---------------------------------------------------------------- storage

  Future<void> load() async {
    final path = _stateFile;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      for (final item in (json['lights'] as List? ?? const [])) {
        final record = BulbRecord.fromJson((item as Map).cast<String, Object?>());
        _bulbs[record.mac] = record;
      }
      _log('Loaded ${_bulbs.length} known light(s) from $path');
    } catch (e) {
      _log('Ignoring unreadable state file $path: $e');
    }
  }

  Future<void> _save() async {
    final path = _stateFile;
    if (path == null) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    const encoder = JsonEncoder.withIndent('  ');
    await tmp.writeAsString(encoder.convert({
      'version': 1,
      'lights': [for (final r in _bulbs.values) r.toJson()],
    }));
    await tmp.rename(path);
  }

  // -------------------------------------------------------------- discovery

  /// Finds bulbs via broadcast and the static list. Returns how many new
  /// bulbs were found. Concurrent calls share one run.
  Future<int> discover() => _discovering ??= _discover().whenComplete(() => _discovering = null);

  Future<int> _discover() async {
    _lastDiscovery = DateTime.now();
    final found = <String, WizEndpoint>{};

    final broadcast = _broadcast;
    if (broadcast != null) {
      try {
        final replies = await _transport.collect(broadcast, WizMessages.registration(),
            listenFor: discoveryListen);
        for (final reply in replies) {
          final mac = reply.result['mac'];
          if (mac is String && mac.isNotEmpty) found[normalizeMac(mac)] = reply.from;
        }
      } on WizException catch (e) {
        _log('Discovery broadcast failed: $e');
      }
    }

    await Future.wait(_staticBulbs.map((endpoint) async {
      try {
        final info = parseSystemConfig(await _transport.request(
            endpoint, WizMessages.getSystemConfig(),
            attempts: readAttempts, attemptTimeout: readTimeout));
        if (info.mac != null) found[normalizeMac(info.mac!)] = endpoint;
      } on WizException catch (e) {
        _log('Static bulb $endpoint not reachable: $e');
      }
    }));

    var added = 0;
    var changed = false;
    final now = DateTime.now();
    for (final MapEntry(key: mac, value: endpoint) in found.entries) {
      var bulb = _bulbs[mac];
      if (bulb == null) {
        bulb = _bulbs[mac] = BulbRecord(mac: mac, name: BulbRecord.defaultName(mac), endpoint: endpoint);
        added++;
        changed = true;
        _log('Found new light $mac at $endpoint');
      } else if (bulb.endpoint != endpoint) {
        _log('Light ${bulb.name} ($mac) moved from ${bulb.endpoint} to $endpoint');
        bulb.endpoint = endpoint;
        changed = true;
      }
      // It just answered, so it is reachable.
      bulb
        ..online = true
        ..lastSeen = now;
    }

    final needInfo = _bulbs.values.where((b) => !b.infoLoaded && found.containsKey(b.mac));
    if ((await Future.wait(needInfo.map(_loadInfo))).any((ok) => ok)) changed = true;
    if (changed) await _save();
    _log('Discovery done: ${found.length} answered, $added new, ${_bulbs.length} known');
    return added;
  }

  /// Reads model, firmware and Kelvin range. Returns true if anything was learned.
  Future<bool> _loadInfo(BulbRecord bulb) async {
    final endpoint = bulb.endpoint;
    if (endpoint == null) return false;
    try {
      final info = parseSystemConfig(await _transport.request(
          endpoint, WizMessages.getSystemConfig(),
          attempts: readAttempts, attemptTimeout: readTimeout));
      bulb.moduleName = info.moduleName;
      bulb.firmware = info.firmware;

      Map<String, Object?>? modelConfig;
      Map<String, Object?>? userConfig;
      try {
        modelConfig = await _transport.request(endpoint, WizMessages.getModelConfig(),
            attempts: readAttempts, attemptTimeout: readTimeout);
      } on WizException {
        // Older firmware has no getModelConfig.
      }
      if (modelConfig?['cctRange'] == null) {
        try {
          userConfig = await _transport.request(endpoint, WizMessages.getUserConfig(),
              attempts: readAttempts, attemptTimeout: readTimeout);
        } on WizException {
          // Not all bulbs have it either; defaults will do.
        }
      }
      final range = parseKelvinRange(modelConfig: modelConfig, userConfig: userConfig);
      bulb.kelvinMin = range.min;
      bulb.kelvinMax = range.max;
      bulb.infoLoaded = true;
      _log('${bulb.name} (${bulb.mac}): model ${bulb.moduleName ?? '?'}, firmware ${bulb.firmware ?? '?'}'
          '${range.min != null ? ', ${range.min}-${range.max} K' : ''}');
      return true;
    } on WizException catch (e) {
      _log('Could not read info for ${bulb.name}: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------- reading

  /// Reads the live state of every known bulb in parallel. Concurrent calls share one run.
  Future<List<Light>> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<List<Light>> _refresh() async {
    await Future.wait(_bulbs.values.map(_readState));

    final missingInfo = _bulbs.values.where((b) => b.online && !b.infoLoaded).toList();
    if (missingInfo.isNotEmpty) {
      if ((await Future.wait(missingInfo.map(_loadInfo))).any((ok) => ok)) await _save();
    }

    final last = _lastDiscovery;
    final anyOffline = _bulbs.values.any((b) => !b.online);
    if (anyOffline && (last == null || DateTime.now().difference(last) > rediscoverAfter)) {
      unawaited(discover().then((_) {}, onError: (Object e) => _log('Discovery failed: $e')));
    }
    return lights;
  }

  Future<void> _readState(BulbRecord bulb) async {
    final endpoint = bulb.endpoint;
    if (endpoint == null) {
      bulb.online = false;
      return;
    }
    try {
      final reading = parsePilot(await _transport.request(endpoint, WizMessages.getPilot(),
          attempts: readAttempts, attemptTimeout: readTimeout));
      bulb
        ..state = reading.state
        ..rssi = reading.rssi
        ..online = true
        ..lastSeen = DateTime.now();
    } on WizException {
      bulb.online = false;
    }
  }

  // ------------------------------------------------------------------ push

  bool get pushEnabled => _advertise != null;

  /// Asks every known bulb to push its status changes to the advertised
  /// address. Must be repeated every [pushKeepAlive]; bulbs that are offline
  /// are simply retried next time.
  Future<void> registerPush() async {
    final address = _advertise;
    if (address == null) return;
    await Future.wait(_bulbs.values.map((b) => _registerPushWith(b, address)));
  }

  Future<void> _registerPushWith(BulbRecord bulb, InternetAddress address) async {
    final endpoint = bulb.endpoint;
    if (endpoint == null) return;
    try {
      await _transport.request(endpoint, WizMessages.registerPush(address.address),
          attempts: 1, attemptTimeout: readTimeout);
    } on WizException {
      // Offline or unplugged; the next keep-alive tries again.
    }
  }

  /// Handles a message a bulb pushed to us (see [registerPush]).
  void handlePush(Map<String, Object?> message, InternetAddress from) {
    final params = message['params'];
    if (params is! Map) return;
    final p = params.cast<String, Object?>();
    final rawMac = p['mac'];
    if (rawMac is! String || rawMac.isEmpty) return;
    final mac = normalizeMac(rawMac);
    final now = DateTime.now();

    switch (message['method']) {
      case 'syncPilot':
        final bulb = _bulbs[mac];
        if (bulb == null) return;
        final reading = parsePilot(p);
        if (bulb.lastPush == null) _log('${bulb.name} ($mac) is pushing status updates');
        bulb
          ..state = reading.state
          ..rssi = reading.rssi ?? bulb.rssi
          ..online = true
          ..lastSeen = now
          ..lastPush = now;
      case 'firstBeat':
        // The bulb just (re)booted, e.g. power came back at the wall switch.
        // It has forgotten our registration, so renew it and read its state.
        var bulb = _bulbs[mac];
        if (bulb == null) {
          bulb = _bulbs[mac] =
              BulbRecord(mac: mac, name: BulbRecord.defaultName(mac), endpoint: WizEndpoint(from));
          _log('Found new light $mac at ${from.address} (it announced itself)');
          unawaited(_loadInfo(bulb).then((_) => _save()).catchError((Object _) {}));
        }
        bulb
          ..online = true
          ..lastSeen = now;
        final address = _advertise;
        if (address != null) unawaited(_registerPushWith(bulb, address));
        unawaited(_readState(bulb));
    }
  }

  // ---------------------------------------------------------------- writing

  /// Applies [command] to one light. Throws [UnknownLightException] or [WizException].
  Future<Light> setState(String id, SetStateCommand command) async {
    final bulb = _bulbs[normalizeMac(id)];
    if (bulb == null) throw UnknownLightException(id);
    final adapted = command.forCapabilities(bulb.capabilities);
    if (adapted.isEmpty) return bulb.toLight();
    await _queue.submit(bulb.mac, adapted.normalized());
    return bulb.toLight();
  }

  /// Applies [command] to all online lights (or the given [ids]) in parallel.
  /// Lights known to be offline are skipped so one unplugged bulb doesn't
  /// slow the group down; they are picked up again by the next refresh.
  /// Lights that were never contacted since startup are tried.
  Future<GroupResult> setGroupState(SetStateCommand command, {List<String>? ids}) async {
    final Iterable<BulbRecord> targets;
    if (ids == null) {
      targets = _bulbs.values.where((b) => b.online || b.lastSeen == null);
    } else {
      targets = ids.map((id) => _bulbs[normalizeMac(id)] ?? (throw UnknownLightException(id)));
    }
    final failed = <String>[];
    await Future.wait(targets.toList().map((bulb) async {
      try {
        await setState(bulb.mac, command);
      } on WizException {
        failed.add(bulb.mac);
      }
    }));
    return GroupResult(lights: lights, failed: failed);
  }

  Future<void> _send(String mac, SetStateCommand command) async {
    final bulb = _bulbs[mac];
    final endpoint = bulb?.endpoint;
    if (bulb == null || endpoint == null) throw WizException('No address known for $mac');
    try {
      await _transport.request(endpoint, WizMessages.setPilot(pilotParams(command)),
          attempts: commandAttempts, attemptTimeout: commandTimeout);
      bulb
        ..state = (bulb.state ?? const LightState(on: false, brightness: maxBrightness))
            .applying(command)
        ..online = true
        ..lastSeen = DateTime.now();
    } on WizException {
      bulb.online = false;
      rethrow;
    }
  }

  Future<Light> rename(String id, String name) async {
    final bulb = _bulbs[normalizeMac(id)];
    if (bulb == null) throw UnknownLightException(id);
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const FormatException('name cannot be empty');
    if (trimmed.length > 64) throw const FormatException('name is too long (max 64)');
    bulb.name = trimmed;
    await _save();
    return bulb.toLight();
  }
}
