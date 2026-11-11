import 'dart:async';

import 'package:diz_core/diz_core.dart';

/// Per-key "latest wins" command queue.
///
/// Dragging a slider produces a burst of commands. Sending them all would
/// flood the bulb and, worse, they could be applied out of order. Instead,
/// at most one command per key is in flight; everything that arrives
/// meanwhile is merged into a single pending command that is sent next.
/// Every caller's future completes once a command containing its change
/// has been acknowledged (or fails with that command's error).
class CoalescingQueue {
  CoalescingQueue(this._send);

  final Future<void> Function(String key, SetStateCommand command) _send;
  final Map<String, _Slot> _slots = {};

  Future<void> submit(String key, SetStateCommand command) {
    final slot = _slots.putIfAbsent(key, _Slot.new);
    final waiter = Completer<void>();
    slot.pending = slot.pending?.mergedWith(command) ?? command;
    slot.waiters.add(waiter);
    if (!slot.busy) unawaited(_drain(key, slot));
    return waiter.future;
  }

  Future<void> _drain(String key, _Slot slot) async {
    slot.busy = true;
    try {
      while (slot.pending != null) {
        final command = slot.pending!;
        final waiters = slot.waiters;
        slot.pending = null;
        slot.waiters = [];
        try {
          await _send(key, command);
          for (final w in waiters) {
            w.complete();
          }
        } catch (error, stack) {
          for (final w in waiters) {
            w.completeError(error, stack);
          }
        }
      }
    } finally {
      slot.busy = false;
    }
  }
}

class _Slot {
  bool busy = false;
  SetStateCommand? pending;
  List<Completer<void>> waiters = [];
}
