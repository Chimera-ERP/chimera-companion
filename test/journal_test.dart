import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/contracts.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('companion-test-');
    file = File('${dir.path}/commands.jsonl');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test('cash cancellation requires a durable rejected receipt on the same equipment',() async {
    final journal=CommandJournal(file);
    expect(await journal.hasRejectedReceipt('missing','ecr'),isFalse);
    for(final outcome in CommandOutcome.values) {
      await journal.execute(id:outcome.name,deviceId:'ecr',operation:'fiscalReceipt',payload:{},
        dispatch:() async=>HardwareResult(outcome,message:'Fixture result'));
      expect(await CommandJournal(file).hasRejectedReceipt(outcome.name,'ecr'),outcome==CommandOutcome.rejected);
      expect(await journal.hasRejectedReceipt(outcome.name,'other-ecr'),isFalse);
    }
    await journal.execute(id:'not-a-receipt',deviceId:'ecr',operation:'nonFiscal',payload:{},
      dispatch:() async=>const HardwareResult(CommandOutcome.rejected,message:'No receipt'));
    expect(await journal.hasRejectedReceipt('not-a-receipt','ecr'),isFalse);
    await file.writeAsString('broken JSON\n',mode:FileMode.append);
    await expectLater(journal.hasRejectedReceipt('rejected','ecr'),throwsFormatException);
  });
  test('payment rejection attestation requires an exact durable terminal outcome across restart',() async {
    final payload=<String,Object?>{'vendor':'fixture','amountMinor':500,'currency':'RON','saleId':'sale','receiptCommandId':'sale','receiptCompanionId':'ecr'};
    final journal=CommandJournal(file);
    expect(await journal.hasRecordedPaymentRejection(id:'absent',deviceId:'terminal',payload:payload),isFalse);
    for(final outcome in [CommandOutcome.rejected,CommandOutcome.unknown,CommandOutcome.succeeded]) {
      await journal.execute(id:outcome.name,deviceId:'terminal',operation:'payment',payload:{...payload,'saleId':outcome.name},dispatch:() async=>HardwareResult(outcome,message:'Fixture terminal result'));
      expect(await CommandJournal(file).hasRecordedPaymentRejection(id:outcome.name,deviceId:'terminal',payload:{...payload,'saleId':outcome.name}),outcome==CommandOutcome.rejected);
    }
    await expectLater(journal.hasRecordedPaymentRejection(id:'rejected',deviceId:'other-terminal',payload:{...payload,'saleId':'rejected'}),throwsStateError);
    await expectLater(journal.hasRecordedPaymentRejection(id:'rejected',deviceId:'terminal',payload:{...payload,'saleId':'rejected','amountMinor':501}),throwsStateError);
    await file.writeAsString('broken JSON\n',mode:FileMode.append);
    await expectLater(journal.hasRecordedPaymentRejection(id:'rejected',deviceId:'terminal',payload:payload),throwsFormatException);
  });
  test('admission command collision scans full history and all equipment after restart',() async {
    final journal=CommandJournal(file);
    await journal.execute(id:'old-sale',deviceId:'old-ecr',operation:'fiscalReceipt',payload:{},dispatch:() async=>const HardwareResult(CommandOutcome.succeeded,message:'Printed'));
    for(var i=0;i<35;i++) {
      await journal.execute(id:'new-diagnostic-$i',deviceId:'new-ecr',operation:'nonFiscal',payload:{},dispatch:() async=>const HardwareResult(CommandOutcome.succeeded,message:'OK'));
    }
    expect(await CommandJournal(file).containsCommandId('old-sale'),isTrue);
    expect(await journal.containsCommandId('unused'),isFalse);
    expect(await journal.confirmedReceiptIds('new-ecr'),isEmpty);
    expect(await journal.confirmedReceiptIds('old-ecr'),{'old-sale'});
    await file.writeAsString('broken JSON\n',mode:FileMode.append);
    await expectLater(journal.containsCommandId('unused'),throwsFormatException);
  });
  test('drawer safety scans all latest outcomes, not just recent diagnostic entries',() async {
    final journal=CommandJournal(file);
    await journal.execute(id:'uncertain',deviceId:'ecr',operation:'cashWithdraw',payload:{'amountMinor':500},
      dispatch:() async=>const HardwareResult(CommandOutcome.unknown,message:'Lost response'));
    for(var i=0;i<35;i++) {
      await journal.execute(id:'diagnostic-$i',deviceId:'ecr',operation:'nonFiscal',payload:{},
        dispatch:() async=>const HardwareResult(CommandOutcome.succeeded,message:'OK'));
    }
    expect((await journal.recent()).any((e)=>e['id']=='uncertain'),isFalse);
    expect(await CommandJournal(file).hasUnresolvedDrawerEffects('ecr'),isTrue);
    expect(await journal.hasUnresolvedDrawerEffects('other-ecr'),isFalse);
  });
  test('confirmed and rejected drawer operations do not block counting; corrupt history does',() async {
    final journal=CommandJournal(file);
    for(final outcome in [CommandOutcome.succeeded,CommandOutcome.rejected]) {
      await journal.execute(id:outcome.name,deviceId:'ecr',operation:'fiscalReceipt',payload:{},
        dispatch:() async=>HardwareResult(outcome,message:'Known'));
    }
    expect(await journal.hasUnresolvedDrawerEffects('ecr'),isFalse);
    await file.writeAsString('broken JSON\n',mode:FileMode.append);
    await expectLater(journal.hasUnresolvedDrawerEffects('ecr'),throwsFormatException);
  });
  test('new authorization metadata preserves old receipt identity without replay', () async {
    var calls=0;
    final payload=<String,Object?>{'operatorId':'alice','operatorName':'Alice','canResetOperatorReport':false,'totalMinor':500};
    await CommandJournal(file).execute(id:'legacy',deviceId:'ecr',operation:'fiscalReceipt',payload:payload,
      dispatch:() async {calls++;return const HardwareResult(CommandOutcome.succeeded,message:'printed');});
    final renewed={...payload,'saleId':'legacy','posId':'pos','checkoutPolicy':{'z_enabled':true},
      'saleAuthorization':{'resultJson':'new proof','signature':'new signature'}};
    expect((await CommandJournal(file).lookup(id:'legacy',deviceId:'ecr',operation:'fiscalReceipt',payload:renewed))?.outcome,CommandOutcome.succeeded);
    await expectLater(CommandJournal(file).lookup(id:'legacy',deviceId:'ecr',operation:'fiscalReceipt',
      payload:{...renewed,'totalMinor':501}),throwsStateError);
    expect(calls,1);
  });
  test('canonical payload order survives restart but business changes do not', () async {
    var calls = 0;
    final journal = CommandJournal(file);
    await journal.execute(
      id: 'canonical', deviceId: 'ecr', operation: 'fiscalReceipt',
      payload: {'operatorId': 'alice', 'line': {'quantity': 1, 'price': 200}},
      dispatch: () async {
        calls++;
        return const HardwareResult(CommandOutcome.succeeded, message: 'OK');
      },
    );
    expect((await CommandJournal(file).lookup(
      id: 'canonical', deviceId: 'ecr', operation: 'fiscalReceipt',
      payload: {'line': {'price': 200, 'quantity': 1}, 'operatorId': 'alice'},
    ))?.outcome, CommandOutcome.succeeded);
    for (final payload in [
      {'operatorId': 'bob', 'line': {'quantity': 1, 'price': 200}},
      {'operatorId': 'alice', 'line': {'quantity': 2, 'price': 200}},
    ]) {
      await expectLater(journal.lookup(
        id: 'canonical', deviceId: 'ecr', operation: 'fiscalReceipt', payload: payload,
      ), throwsStateError);
    }
    expect(calls, 1);
  });
  test('fiscal identities survive restart without a second dispatch',() async {
    var calls=0;
    Future<HardwareResult> run()=>CommandJournal(file).execute(id:'receipt-proof',deviceId:'ecr',operation:'fiscalReceipt',payload:{'totalMinor':1000},dispatch:() async {
      calls++;return const HardwareResult(CommandOutcome.succeeded,message:'Printed',fiscalIdentity:{'receiptNumber':'0000001','zNumber':'0002'});
    });
    expect((await run()).fiscalIdentity['receiptNumber'],'0000001');
    expect((await run()).fiscalIdentity['zNumber'],'0002');
    expect((await CommandJournal(file).lookup(id:'receipt-proof',deviceId:'ecr',operation:'fiscalReceipt',payload:{'totalMinor':1000}))?.fiscalIdentity['receiptNumber'],'0000001');
    expect(calls,1);
  });
  test(
    'one confirmed payment cannot back two different fiscal commands',
    () async {
      final journal = CommandJournal(file);
      Future<HardwareResult> run(String id) => journal.execute(
        id: id,
        deviceId: 'ecr',
        operation: 'fiscalReceipt',
        payload: {'paymentCommandId': 'viva-1'},
        dispatch: () async => const HardwareResult(
          CommandOutcome.succeeded,
          reference: '42',
          message: 'OK',
        ),
      );
      expect((await run('receipt-1')).outcome, CommandOutcome.succeeded);
      expect((await run('receipt-1')).reference, '42');
      await expectLater(run('receipt-2'), throwsStateError);
      final entries = await journal.recent();
      expect(entries, hasLength(1));
      expect(entries.single['operation'], 'fiscalReceipt');
      expect(entries.single.containsKey('hash'), false);
      expect(
        (await journal.lookup(
          id: 'receipt-1',
          deviceId: 'ecr',
          operation: 'fiscalReceipt',
          payload: {'paymentCommandId': 'viva-1'},
        ))?.outcome,
        CommandOutcome.succeeded,
      );
      await expectLater(
        journal.lookup(
          id: 'receipt-1',
          deviceId: 'other-ecr',
          operation: 'fiscalReceipt',
          payload: {'paymentCommandId': 'viva-1'},
        ),
        throwsStateError,
      );
    },
  );
  test(
    'restart and duplicate commands return the persisted result, once',
    () async {
      var calls = 0;
      Future<HardwareResult> run(CommandJournal journal, {int amount = 2000}) =>
          journal.execute(
            id: 'cmd-1',
            deviceId: 'ecr',
            operation: 'receipt',
            payload: {'amount': amount},
            dispatch: () async {
              calls++;
              return const HardwareResult(
                CommandOutcome.succeeded,
                reference: '0001',
                message: 'Confirmed',
              );
            },
          );
      expect(
        (await run(CommandJournal(file))).outcome,
        CommandOutcome.succeeded,
      );
      expect((await run(CommandJournal(file))).reference, '0001');
      expect(calls, 1);
      await expectLater(
        run(CommandJournal(file), amount: 2001),
        throwsStateError,
      );
    },
  );
  test('unknown dispatch result is never retried', () async {
    var calls = 0;
    Future<HardwareResult> run() => CommandJournal(file).execute(
      id: 'cmd',
      deviceId: 'ecr',
      operation: 'receipt',
      payload: {},
      dispatch: () async {
        calls++;
        throw StateError('Crash after write');
      },
    );
    expect((await run()).outcome, CommandOutcome.unknown);
    expect((await run()).outcome, CommandOutcome.unknown);
    expect(calls, 1);
  });
  test('process interrupted after journal flush remains unknown', () async {
    final journal = CommandJournal(file);
    await journal.execute(
      id: 'cmd',
      deviceId: 'ecr',
      operation: 'receipt',
      payload: {},
      dispatch: () async =>
          const HardwareResult(CommandOutcome.succeeded, message: 'OK'),
    );
    final first = (await file.readAsLines()).first;
    await file.writeAsString('$first\n');
    var called = false;
    final result = await CommandJournal(file).execute(
      id: 'cmd',
      deviceId: 'ecr',
      operation: 'receipt',
      payload: {},
      dispatch: () async {
        called = true;
        return const HardwareResult(CommandOutcome.succeeded, message: 'OK');
      },
    );
    expect(result.outcome, CommandOutcome.unknown);
    expect(called, false);
  });
  test(
    'concurrent instances sharing a journal cannot dispatch concurrently',
    () async {
      final release = Completer<void>();
      final entered = Completer<void>();
      final one = CommandJournal(file).execute(
        id: 'one',
        deviceId: 'ecr',
        operation: 'receipt',
        payload: {},
        dispatch: () async {
          entered.complete();
          await release.future;
          return const HardwareResult(CommandOutcome.succeeded, message: 'OK');
        },
      );
      await entered.future;
      final two = await CommandJournal(file).execute(
        id: 'two',
        deviceId: 'ecr',
        operation: 'receipt',
        payload: {},
        dispatch: () async => throw StateError('Must not run'),
      );
      expect(two.outcome, CommandOutcome.rejected);
      release.complete();
      await one;
    },
  );
  test('malformed journal fails closed before dispatch', () async {
    await file.writeAsString('{torn');
    await expectLater(
      CommandJournal(file).execute(
        id: 'cmd',
        deviceId: 'ecr',
        operation: 'receipt',
        payload: {},
        dispatch: () async => throw StateError('Must not run'),
      ),
      throwsFormatException,
    );
  });
}
