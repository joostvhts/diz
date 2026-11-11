import 'dart:async';

import 'package:diz_core/diz_core.dart';
import 'package:flutter/widgets.dart';

import '../api/bridge_client.dart';
import '../util/command_throttle.dart';

/// Key used for "all lights" in the throttle and the UI.
const String groupKey = '*';

/// App state: the list of lights, kept fresh by polling while the app is in
/// the foreground, with optimistic updates for every change the user makes.
class LightsController extends ChangeNotifier with WidgetsBindingObserver {
  LightsController({
    required this.api,
    this.pollInterval = const Duration(seconds: 5),
    Duration throttleInterval = const Duration(milliseconds: 120),
    this.localEditGrace = const Duration(seconds: 2),
  }) {
    _throttle = CommandThrottle(interval: throttleInterval, send: _send);
  }

  final LightsApi api;
  final Duration pollInterval;

  /// After a local change, polled state for that light is ignored for this
  /// long so sliders don't jump back while the bulb catches up.
  final Duration localEditGrace;

  late final CommandThrottle _throttle;
  final _messages = StreamController<String>.broadcast();
  final Map<String, DateTime> _localEdits = {};
  Timer? _pollTimer;
  bool _started = false;
  bool _disposed = false;

  List<Light> _lights = const [];
  bool _loading = false;
  bool _loaded = false;
  String? _error;
  BridgeHealth? _health;

  List<Light> get lights => _lights;
  List<Light> get onlineLights => [for (final l in _lights) if (l.online) l];

  /// True while a refresh is running.
  bool get loading => _loading;

  /// True once the first successful refresh completed.
  bool get loaded => _loaded;

  /// Why the bridge can't be reached, or null if it can.
  String? get error => _error;
  BridgeHealth? get health => _health;

  /// One-off messages for snackbars (e.g. a light that didn't respond).
  Stream<String> get messages => _messages.stream;

  Light? light(String id) {
    for (final l in _lights) {
      if (l.id == id) return l;
    }
    return null;
  }

  bool get anyOn => _lights.any((l) => l.isOn);

  /// Everything at least one online light can do.
  Capabilities get groupCapabilities =>
      onlineLights.fold(Capabilities.none, (caps, l) => caps.union(l.capabilities));

  /// A representative state for "all lights": on if any is on, the average
  /// brightness of the lights that are on, and the look of the first one.
  LightState? get groupState {
    final online = onlineLights.where((l) => l.state != null).toList();
    if (online.isEmpty) return null;
    final on = online.where((l) => l.state!.on).toList();
    final basis = on.isNotEmpty ? on : online;
    final brightness =
        (basis.map((l) => l.state!.brightness).reduce((a, b) => a + b) / basis.length).round();
    final first = basis.first.state!;
    return LightState(
      on: on.isNotEmpty,
      brightness: brightness,
      mode: first.mode,
      rgb: first.rgb,
      kelvin: first.kelvin,
      sceneId: first.sceneId,
    );
  }

  // ------------------------------------------------------------ lifecycle

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
    _startPolling();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(refresh());
        _startPolling();
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _pollTimer?.cancel();
        _pollTimer = null;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _throttle.dispose();
    if (_started) WidgetsBinding.instance.removeObserver(this);
    unawaited(_messages.close());
    api.close();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // -------------------------------------------------------------- reading

  Future<void> refresh() async {
    if (_loading || _disposed) return;
    _loading = true;
    _notify();
    try {
      _health ??= await api.health();
      final fresh = await api.lights();
      if (_disposed) return;
      _lights = [for (final l in fresh) _keepLocalEdits(l)];
      _error = null;
      _loaded = true;
    } on BridgeException catch (e) {
      _error = e.message;
      _health = null;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Keeps the optimistic state of a light that was just changed locally.
  Light _keepLocalEdits(Light fresh) {
    final editedAt = _localEdits[fresh.id];
    final groupEditedAt = _localEdits[groupKey];
    final latest = [editedAt, groupEditedAt].whereType<DateTime>().fold<DateTime?>(
        null, (a, b) => a == null || b.isAfter(a) ? b : a);
    final recent = latest != null && DateTime.now().difference(latest) < localEditGrace;
    final busy = _throttle.isBusy(fresh.id) || _throttle.isBusy(groupKey);
    if (!recent && !busy) return fresh;
    final current = light(fresh.id);
    if (current?.state == null || !fresh.online) return fresh;
    return fresh.copyWith(state: current!.state);
  }

  // -------------------------------------------------------------- writing

  /// Changes one light. The UI updates immediately; the request is throttled.
  void setLight(String id, SetStateCommand command) {
    final current = light(id);
    if (current == null) return;
    _applyLocally(current, command);
    _localEdits[id] = DateTime.now();
    _notify();
    _throttle.push(id, command);
  }

  /// Changes all online lights. The bridge adapts the command per light.
  void setGroup(SetStateCommand command) {
    for (final l in onlineLights) {
      _applyLocally(l, command);
    }
    _localEdits[groupKey] = DateTime.now();
    _notify();
    _throttle.push(groupKey, command);
  }

  void _applyLocally(Light target, SetStateCommand command) {
    final adapted = command.forCapabilities(target.capabilities);
    if (adapted.isEmpty) return;
    final state =
        (target.state ?? const LightState(on: false, brightness: maxBrightness)).applying(adapted);
    _lights = [for (final l in _lights) l.id == target.id ? l.copyWith(state: state) : l];
  }

  Future<void> _send(String key, SetStateCommand command) async {
    try {
      if (key == groupKey) {
        final result = await api.setGroup(command);
        if (result.failed.isNotEmpty) {
          final names = result.failed.map((id) => light(id)?.name ?? id).join(', ');
          _message('No response from $names');
        }
      } else {
        await api.setLight(key, command);
      }
    } on BridgeException catch (e) {
      _message(e.statusCode == 504 ? '${light(key)?.name ?? 'The light'} did not respond' : e.message);
      _localEdits.remove(key);
      unawaited(refresh());
    }
  }

  void _message(String text) {
    if (!_disposed) _messages.add(text);
  }

  // ---------------------------------------------------------------- admin

  Future<void> rename(String id, String name) async {
    final updated = await api.rename(id, name);
    _lights = [for (final l in _lights) l.id == id ? updated : l]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _notify();
  }

  /// Asks the bridge to look for new lights. Returns how many were found.
  Future<int> discover() async {
    final result = await api.discover();
    _lights = result.lights;
    _notify();
    return result.added;
  }
}
