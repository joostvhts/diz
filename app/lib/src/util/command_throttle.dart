import 'dart:async';

import 'package:diz_core/diz_core.dart';

/// Rate-limits commands per key (a light id or the group) while a slider or
/// the color wheel is being dragged.
///
/// * At most one request per key is in flight, so requests can't overtake
///   each other on the way to the bridge.
/// * Requests are at least [interval] apart.
/// * Everything that arrives in between is merged into one pending command,
///   so the final value of a drag is always sent.
class CommandThrottle {
  CommandThrottle({required this.interval, required this.send});

  final Duration interval;

  /// Performs the request. Errors are the caller's to report; they are
  /// swallowed here so the queue keeps going.
  final Future<void> Function(String key, SetStateCommand command) send;

  final Map<String, _Slot> _slots = {};
  bool _disposed = false;

  void push(String key, SetStateCommand command) {
    if (_disposed) return;
    final slot = _slots.putIfAbsent(key, _Slot.new);
    slot.pending = slot.pending?.mergedWith(command) ?? command;
    _pump(key, slot);
  }

  /// Whether anything is queued or in flight for [key].
  bool isBusy(String key) {
    final slot = _slots[key];
    return slot != null && (slot.inFlight || slot.pending != null);
  }

  void _pump(String key, _Slot slot) {
    if (_disposed || slot.inFlight || slot.timer != null || slot.pending == null) return;
    final last = slot.lastSent;
    if (last != null) {
      final since = DateTime.now().difference(last);
      if (since < interval) {
        slot.timer = Timer(interval - since, () {
          slot.timer = null;
          _pump(key, slot);
        });
        return;
      }
    }
    final command = slot.pending!;
    slot
      ..pending = null
      ..inFlight = true
      ..lastSent = DateTime.now();
    Future.sync(() => send(key, command)).catchError((Object _) {}).whenComplete(() {
      slot.inFlight = false;
      _pump(key, slot);
    });
  }

  void dispose() {
    _disposed = true;
    for (final slot in _slots.values) {
      slot.timer?.cancel();
    }
    _slots.clear();
  }
}

class _Slot {
  SetStateCommand? pending;
  bool inFlight = false;
  DateTime? lastSent;
  Timer? timer;
}
