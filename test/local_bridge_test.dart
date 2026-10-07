import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/local_bridge.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/fiscal_device.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'adapters_test.dart' as fixtures;
import 'payment_admission_test.dart' as payments;

class FakeFiscalDevice extends FiscalDevice {
  FakeFiscalDevice() : super(fixtures.connection());
  Future<DeviceStatus>? pendingRead;
  bool offline = false;
  int prints = 0, reports = 0;
  final operatorCalls = <Map<String, dynamic>>[];
  @override
  Future<Map<String, Object?>> setOperator({
    required String commandId, required Map<String, dynamic> identity,
    required bool ending, required CommandJournal journal,
    required Future<Map<String, dynamic>?> Function(String) read,
    required Future<void> Function(String, Map<String, dynamic>) write,
  }) async {
    operatorCalls.add({'id': commandId, 'identity': identity, 'ending': ending});
    return {'outcome': 'succeeded'};
  }
  @override
  Future<DeviceStatus> readStatus() async {
    if (offline) throw const SocketException('offline');
    return await pendingRead ?? const DeviceStatus(ready: true, description: 'Ready');
  }
  @override
  Future<HardwareResult> nonFiscal(List<String> lines) async {
    prints++;
    return const HardwareResult(CommandOutcome.succeeded, message: 'Printed');
  }

  @override
  Future<HardwareResult> report({required bool closeDay}) async {
    reports++;
    return const HardwareResult(CommandOutcome.succeeded, message: 'Reported');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocalBridge bridge;
  late FakeFiscalDevice device;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({'local_hardware_v1': '{}'});
    dir = await Directory.systemTemp.createTemp('companion-bridge-test-');
    device = FakeFiscalDevice();
    bridge = LocalBridge(
      journal: CommandJournal(File('${dir.path}/journal')),
      deviceFactory: (_) => device,
    );
  });
  tearDown(() async {
    await bridge.close();
    await dir.delete(recursive: true);
  });
  test('status checks the ECR without printing and reports unavailable hardware', () async {
    final status = await bridge.run('status', 'status-ready', {});
    expect(status['outcome'], 'succeeded');
    expect(status['ecrReady'], isTrue);
    device.offline = true;
    final unavailable = await bridge.run('status', 'status-offline', {});
    expect(unavailable['ecrReady'], isFalse);
    expect(unavailable['message'], contains('oprită sau inaccesibilă'));
    expect(device.prints, 0);
    expect(device.reports, 0);
  });
  test('operator API delegates lifecycle to the device, without composing reports', () async {
    final identity = {'operatorId': 'one', 'operatorName': 'Ana'};
    expect((await bridge.run('operatorLogin', 'enter', identity))['outcome'], 'succeeded');
    await bridge.refresh();
    expect((await bridge.run('operatorLogout', 'exit', identity))['outcome'], 'succeeded');
    expect(device.operatorCalls, [
      {'id': 'enter', 'identity': identity, 'ending': false},
      {'id': 'exit', 'identity': identity, 'ending': true},
    ]);
    expect(device.reports, 0);
  });
  test('legacy recovery without a journal entry cannot issue a new receipt',() async {
    final result=await bridge.run('fiscalReceipt','legacy-missing',{'recoveryOnly':true});
    expect(result['outcome'],'unknown');expect(result['message'],contains('nu execută'));
    expect(device.prints,0);expect(device.reports,0);
  });
  for (final operation in ['xReport','zReport','nonFiscal','cashDeposit','cashWithdraw','fiscalReceipt']) {
    test('read-only $operation recovery cannot dispatch when its journal entry is absent',() async {
      final payload=<String,dynamic>{'recoveryOnly':true,
        if(operation=='zReport')'confirmCloseDay':true};
      final result=await bridge.run(operation,'missing',payload);
      expect(result['outcome'],'unknown');
      expect(result['journalFound'],isNot(true));
      expect(await CommandJournal(File('${dir.path}/journal')).recent(),isEmpty);
      expect(device.prints,0);expect(device.reports,0);
    });
  }
  for (final operation in ['xReport','zReport','nonFiscal']) {
    for (final outcome in CommandOutcome.values) {
      test('read-only $operation recovers the exact $outcome result with ECR unavailable',() async {
        final payload=<String,dynamic>{if(operation=='zReport')'confirmCloseDay':true,
          if(operation=='nonFiscal')'lines':['TEST']};
        final journal=CommandJournal(File('${dir.path}/journal'));
        await journal.execute(id:'original',deviceId:device.id,operation:operation,payload:payload,
          dispatch:() async=>HardwareResult(outcome,message:'Original',reference:'original-ref'));
        final original=await journal.file.readAsString();
        device.offline=true;
        final result=await bridge.run(operation,'original',{...payload,'recoveryOnly':true});
        expect(result['outcome'],outcome.name);expect(result['journalFound'],true);
        expect(result['reference'],'original-ref');
        expect(await journal.file.readAsString(),original);
        expect(device.prints,0);expect(device.reports,0);
      });
    }
  }
  test('read-only recovery still rejects an altered report payload',() async {
    final journal=CommandJournal(File('${dir.path}/journal'));
    await journal.execute(id:'original',deviceId:device.id,operation:'zReport',payload:{'confirmCloseDay':true},
      dispatch:() async=>const HardwareResult(CommandOutcome.succeeded,message:'Original'));
    await expectLater(bridge.run('zReport','original',{'confirmCloseDay':true,'unexpected':'changed','recoveryOnly':true}),throwsStateError);
    expect(device.reports,0);
  });
  test('payment-test read-only recovery never calls Viva and retains original terminal identity',() async {
    final terminal=payments.Terminal();
    FlutterSecureStorage.setMockInitialValues({'local_hardware_v1':'{"vivaEnabled":"false","vivaHost":"127.0.0.1","vivaPort":"9564"}'});
    final journal=CommandJournal(File('${dir.path}/journal'));
    await bridge.close();
    bridge=LocalBridge(journal:journal,deviceFactory:(_)=>device,paymentFactory:(_)=>terminal);
    final payload={'amountMinor':500,'currency':'RON','recoveryOnly':true};
    expect((await bridge.run('paymentTest','absent',payload))['outcome'],'unknown');
    expect(await journal.recent(),isEmpty);
    await journal.execute(id:'original',deviceId:'127.0.0.1:9564',operation:'payment',
      payload:{'vendor':'fixture','amountMinor':500,'currency':'RON'},
      dispatch:() async=>const HardwareResult(CommandOutcome.succeeded,message:'Paid',reference:'bank-ref'));
    final result=await bridge.run('paymentTest','original',payload);
    expect(result['outcome'],'succeeded');expect(result['journalFound'],true);
    expect(result['reference'],'bank-ref');expect(terminal.calls,0);
    await expectLater(bridge.run('paymentTest','original',{'amountMinor':501,'currency':'RON','recoveryOnly':true}),throwsArgumentError);
    expect(terminal.calls,0);
  });
  test('drawer count is persistent and blocks new fiscal commands across POS operators', () async {
    final owner = {'shiftId':'shift_test123','operatorId':'one'};
    expect((await bridge.run('drawerCountStart','lock-one',owner))['outcome'],'succeeded');
    expect((await bridge.run('drawerCountStart','retry-lock',owner))['outcome'],'succeeded');
    expect((await bridge.run('drawerCountStart','other',{'shiftId':'shift_other123','operatorId':'two'}))['outcome'],'rejected');
    expect((await bridge.run('fiscalReceipt','new-sale',{'operatorId':'two'}))['message'],contains('numărare'));
    expect((await bridge.run('drawerCountEnd','bad-release',{'shiftId':'shift_test123','operatorId':'two'}))['outcome'],'rejected');
    expect((await bridge.run('drawerCountEnd','release',owner))['outcome'],'succeeded');
    expect(device.prints,0);expect(device.reports,0);
  });
  test('unknown hardware cash result from another POS blocks drawer reservation after restart',() async {
    await CommandJournal(File('${dir.path}/journal')).execute(id:'other-pos-cash',deviceId:device.id,
      operation:'cashWithdraw',payload:{'operatorId':'other','amountMinor':500},
      dispatch:() async=>const HardwareResult(CommandOutcome.unknown,message:'Lost response'));
    final result=await bridge.run('drawerCountStart','lock',{'shiftId':'shift_test123','operatorId':'one'});
    expect(result['outcome'],'rejected');expect(result['message'],contains('neconfirmat'));
    expect(await const FlutterSecureStorage().read(key:'cash_drawer_count_v1'),isNull);
    expect(device.prints,0);expect(device.reports,0);
  });
  for(final uncertainOperation in ['cashWithdraw','fiscalReceipt']) {
    test('unknown $uncertainOperation blocks new cash but preserves original recovery',() async {
      final payload={'operatorId':'other','amountMinor':500,'currency':'RON','reason':'Test'};
      final journal=CommandJournal(File('${dir.path}/journal'));
      await journal.execute(id:'uncertain',deviceId:device.id,operation:uncertainOperation,payload:payload,
        dispatch:() async=>const HardwareResult(CommandOutcome.unknown,message:'Lost response'));
      for(final operation in ['cashDeposit','cashWithdraw']) {
        final result=await bridge.run(operation,'new-$operation',payload);
        expect(result['outcome'],'rejected');expect(result['message'],contains('neconfirmat'));
      }
      final recovered=await bridge.run(uncertainOperation,'uncertain',payload);
      expect(recovered['outcome'],'unknown');expect(recovered['message'],'Lost response');
      expect((await journal.recent()).length,1);
      expect(device.prints,0);expect(device.reports,0);
    });
  }
  test('persisted sale admission blocks counting until its receipt is confirmed, even after expiry',() async {
    await const FlutterSecureStorage().write(key:'sale_admission_fixture',value:'{"saleId":"admitted","expiresAt":1}');
    final owner={'shiftId':'shift_test123','operatorId':'one'};
    expect((await bridge.run('drawerCountStart','start',owner))['message'],contains('nefinalizată'));
    final journal=CommandJournal(File('${dir.path}/journal'));
    await journal.execute(id:'admitted',deviceId:device.id,operation:'fiscalReceipt',payload:{},dispatch:() async=>const HardwareResult(CommandOutcome.rejected,message:'Printer refused'));
    expect((await bridge.run('drawerCountStart','again',owner))['outcome'],'rejected');
    await journal.execute(id:'confirmed',deviceId:device.id,operation:'fiscalReceipt',payload:{},dispatch:() async=>const HardwareResult(CommandOutcome.succeeded,message:'Printed'));
    await const FlutterSecureStorage().write(key:'sale_admission_fixture',value:'{"saleId":"confirmed","expiresAt":1}');
    expect((await bridge.run('drawerCountStart','settled',owner))['outcome'],'succeeded');
  });
  test('a valid persisted unpaid cancellation releases counting without a fiscal command',() async {
    await const FlutterSecureStorage().write(key:'sale_admission_cancelled',value:'{"saleId":"cancelled","receiptHash":"${'a'*64}","amountMinor":500,"currency":"RON","lifecycleVersion":1,"phase":"abandoned"}');
    expect((await bridge.run('drawerCountStart','start',{'shiftId':'shift_test123','operatorId':'one'}))['outcome'],'succeeded');
    expect(device.prints,0);expect(device.reports,0);
  });
  test(
    'a duplicate during a background check waits and returns the original outcome',
    () async {
      final payload = {
        'lines': ['TEST'],
      };
      expect(
        (await bridge.run('nonFiscal', 'same-id', payload))['outcome'],
        'succeeded',
      );
      await bridge.refresh();
      final read = Completer<DeviceStatus>();
      device.pendingRead = read.future;
      final refresh = bridge.refresh();
      await Future<void>.delayed(Duration.zero);
      var finished = false;
      final replay = bridge.run('nonFiscal', 'same-id', payload).then((value) {
        finished = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, false);
      read.complete(const DeviceStatus(ready: true, description: 'Ready'));
      await refresh;
      expect((await replay)['outcome'], 'succeeded');
      expect(device.prints, 1);
      await bridge.refresh();
    },
  );
  test(
    'Z requires explicit confirmation at dispatch, not just in UI',
    () async {
      await expectLater(bridge.run('zReport', 'z-1', {}), throwsArgumentError);
      expect(device.reports, 0);
      await bridge.refresh();
      expect(
        (await bridge.run('zReport', 'z-2', {
          'confirmCloseDay': true,
        }))['outcome'],
        'succeeded',
      );
      await bridge.refresh();
      expect(
        (await bridge.run('zReport', 'z-2', {
          'confirmCloseDay': true,
        }))['outcome'],
        'succeeded',
      );
      expect(device.reports, 1);
      await bridge.refresh();
    },
  );
}
