import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/command_executor.dart';

void main() {
  test(
    'concurrent identical command joins one dispatch; changed payload is rejected',
    () async {
      final executor = HardwareCommandExecutor(), release = Completer<void>();
      var calls = 0;
      Future<Map<String, Object?>> run(int amount) => executor.execute(
        equipment: 'viva',
        id: 'payment',
        operation: 'payment',
        payload: {'amount': amount},
        dispatch: () async {
          calls++;
          await release.future;
          return {'outcome': 'unknown'};
        },
      );
      final first = run(500), duplicate = run(500);
      await expectLater(run(501), throwsStateError);
      release.complete();
      expect(await first, await duplicate);
      expect(calls, 1);
    },
  );
  test(
    'equipment commands queue and a rejected command does not poison later jobs',
    () async {
      final executor = HardwareCommandExecutor(), release = Completer<void>();
      final events = <String>[];
      final a = executor.execute(
        equipment: 'ecr',
        id: 'a',
        operation: 'nonFiscal',
        payload: {},
        dispatch: () async {
          events.add('a');
          await release.future;
          throw StateError('failed');
        },
      );
      final handled = a.catchError((_) => {'outcome': 'rejected'});
      final b = executor.execute(
        equipment: 'ecr',
        id: 'b',
        operation: 'nonFiscal',
        payload: {},
        dispatch: () async {
          events.add('b');
          return {'outcome': 'succeeded'};
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, ['a']);
      release.complete();
      await handled;
      expect((await b)['outcome'], 'succeeded');
      expect(events, ['a', 'b']);
    },
  );
}
