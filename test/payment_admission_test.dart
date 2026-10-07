import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/runtime.dart';

class Terminal implements PaymentTerminalAdapter {
  int calls = 0;
  CommandOutcome outcome = CommandOutcome.succeeded;
  @override
  String get vendor => 'fixture';
  @override
  Future<HardwareResult> pay(PaymentRequest request) async {
    calls++;
    return HardwareResult(
      outcome,
      message: 'fixture',
      reference: outcome == CommandOutcome.succeeded ? 'bank-ref' : null,
    );
  }

  @override
  Future<HardwareResult> reconcile(PaymentRequest request) async =>
      throw UnimplementedError();
}

void main() {
  late Directory directory;
  late CommandJournal journal;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('payment-admission-');
    journal = CommandJournal(File('${directory.path}/journal'));
  });
  tearDown(() async => directory.delete(recursive: true));
  final request = PaymentRequest(
    commandId: 'payment-1',
    amountMinor: 500,
    currency: 'RON',
  );
  const binding = {
    'saleId': 'sale-1',
    'receiptCommandId': 'sale-1',
    'receiptCompanionId': 'ecr',
  };
  test('read-only payment recovery cannot start a missing payment or run preflight',() async {
    final terminal=Terminal();
    var checks=0;
    final result=await HardwareRuntime(journal).payment('terminal',terminal,request,
      binding:binding,recoveryOnly:true,preflight:() async{checks++;});
    expect(result.outcome,CommandOutcome.unknown);
    expect(terminal.calls,0);expect(checks,0);expect(await journal.recent(),isEmpty);
  });
  test(
    'invalid admission rejects before bank dispatch or in-flight journal',
    () async {
      final terminal = Terminal();
      await expectLater(
        HardwareRuntime(journal).payment(
          'terminal',
          terminal,
          request,
          binding: binding,
          preflight: () async =>
              throw const FormatException('expired admission'),
        ),
        throwsFormatException,
      );
      expect(terminal.calls, 0);
      expect(await journal.recent(), isEmpty);
    },
  );
  test(
    'confirmed payment recovers after authorization expires without paying again',
    () async {
      final terminal = Terminal();
      var checks = 0;
      await HardwareRuntime(journal).payment(
        'terminal',
        terminal,
        request,
        binding: binding,
        preflight: () async {
          checks++;
        },
      );
      final recovered = await HardwareRuntime(journal).payment(
        'terminal',
        terminal,
        request,
        binding: binding,
        preflight: () async => throw const FormatException('expired admission'),
      );
      expect(recovered.reference, 'bank-ref');
      expect(terminal.calls, 1);
      expect(checks, 1);
    },
  );
  test(
    'unknown payment remains unknown and is not dispatched with renewed permission',
    () async {
      final terminal = Terminal()..outcome = CommandOutcome.unknown;
      await HardwareRuntime(journal).payment(
        'terminal',
        terminal,
        request,
        binding: binding,
        preflight: () async {},
      );
      final recovered = await HardwareRuntime(journal).payment(
        'terminal',
        terminal,
        request,
        binding: binding,
        preflight: () async => throw const FormatException('must not execute'),
      );
      expect(recovered.outcome, CommandOutcome.unknown);
      expect(terminal.calls, 1);
    },
  );
  test('a new payment command ID cannot charge an admitted sale twice',() async {
    final terminal=Terminal();
    await HardwareRuntime(journal).payment('terminal',terminal,request,binding:binding,preflight:() async {});
    await expectLater(HardwareRuntime(journal).payment('terminal',terminal,
      PaymentRequest(commandId:'another-payment-id',amountMinor:500,currency:'RON'),
      binding:binding,preflight:() async {}),throwsStateError);
    expect(terminal.calls,1);
  });
}
