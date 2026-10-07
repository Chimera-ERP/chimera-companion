import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/datecs_rou_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chimera/hardware/datecs_rou');
  final connection = FiscalConnection(
    id: 'datecs',
    model: FiscalModel.datecsDp25,
    endpoint: LanEndpoint(host: '192.168.1.25', port: 9100),
    operatorNumber: 1,
    operatorPassword: '1234',
    cashPaymentCode: 'P',
    cardPaymentCode: 'D',
  );
  final receipt = FiscalReceipt(
    commandId: 'cmd',
    currency: 'RON',
    totalMinor: 2000,
    paymentMethod: FiscalPaymentMethod.cash,
    lines: [
      FiscalLine(
        name: 'Cafea',
        quantityDecimal: '1',
        unitPriceMinor: 2000,
        grossTotalMinor: 2000,
        vatGroup: 'A',
      ),
    ],
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'X report has dedicated native operation, cannot carry Z option or operator credentials',
    () async {
      MethodCall? sent;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            sent = call;
            return {'outcome': 'succeeded', 'message': 'Raport X confirmat'};
          });
      final result = await DatecsRouAdapter.printXReport(connection.endpoint);
      expect(result.outcome, CommandOutcome.succeeded);
      expect(sent!.method, 'xReport');
      expect(sent!.arguments, {'host': '192.168.1.25', 'port': 9100});
    },
  );
  test('Lost X reply is unknown and not retried', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          calls++;
          throw PlatformException(code: 'LOST_REPLY');
        });
    expect(
      (await DatecsRouAdapter.printXReport(connection.endpoint)).outcome,
      CommandOutcome.unknown,
    );
    expect(calls, 1);
  });
  test(
    'Datecs SDK bridge receives exact amount and configured payment codes',
    () async {
      MethodCall? sent;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            sent = call;
            return {
              'outcome': 'succeeded',
              'reference': '0001',
              'message': 'OK',
            };
          });
      expect(
        (await DatecsRouAdapter(connection).printReceipt(receipt)).outcome,
        CommandOutcome.succeeded,
      );
      final args = sent!.arguments as Map;
      expect((args['receipt'] as Map)['totalMinor'], 2000);
      expect(args['cashPaymentCode'], 'P');
      expect(sent!.method, 'receipt');
    },
  );
  test(
    'missing fiscal identity or lost native reply cannot confirm a receipt',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {'outcome': 'succeeded'},
          );
      expect(
        (await DatecsRouAdapter(connection).printReceipt(receipt)).outcome,
        CommandOutcome.unknown,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: 'LOST_REPLY'),
          );
      expect(
        (await DatecsRouAdapter(connection).printReceipt(receipt)).outcome,
        CommandOutcome.unknown,
      );
    },
  );
}
