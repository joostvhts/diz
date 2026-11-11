import 'dart:async';

import 'package:diz_bridge/diz_bridge.dart';
import 'package:diz_core/diz_core.dart';
import 'package:test/test.dart';

void main() {
  test('bursts are coalesced into one in-flight and one merged pending command', () async {
    final sent = <SetStateCommand>[];
    final gate = Completer<void>();
    final queue = CoalescingQueue((key, command) async {
      sent.add(command);
      if (sent.length == 1) await gate.future;
    });

    final futures = [
      queue.submit('a', const SetStateCommand(brightness: 10)),
      queue.submit('a', const SetStateCommand(brightness: 20)),
      queue.submit('a', const SetStateCommand(kelvin: 3000)),
      queue.submit('a', const SetStateCommand(brightness: 30)),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(sent, [const SetStateCommand(brightness: 10)]);

    gate.complete();
    await Future.wait(futures);
    expect(sent, [
      const SetStateCommand(brightness: 10),
      const SetStateCommand(on: true, brightness: 30, kelvin: 3000),
    ]);
  });

  test('keys are independent and errors reach every waiter of that command', () async {
    final queue = CoalescingQueue((key, command) async {
      if (key == 'bad') throw const WizTimeoutException('nope');
    });
    await queue.submit('good', const SetStateCommand(on: true));
    await expectLater(queue.submit('bad', const SetStateCommand(on: true)),
        throwsA(isA<WizTimeoutException>()));
    // The queue keeps working after a failure.
    await queue.submit('good', const SetStateCommand(on: false));
  });
}
