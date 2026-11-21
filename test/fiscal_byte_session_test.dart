import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/datecs_device_client.dart';
import 'package:chimera_companion/hardware/datecs_gateway_protocol.dart';
import 'package:chimera_companion/hardware/fiscal_byte_session.dart';
import 'package:chimera_companion/hardware/fiscal_device.dart';
import 'package:chimera_companion/hardware/tremol_protocol.dart';
import 'adapters_test.dart' show TremolPeer;
import 'fiscal_device_test.dart' show FiscalPeer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chimera/fiscal-serial');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const mac = 'AA:BB:CC:DD:EE:FF';
  String key(String model, String serial) =>
      sha256.convert(utf8.encode('fiscal/$model/$serial')).toString();
  String usbId(String model) =>
      key(model, model == 'datecsDp25' ? 'DTTEST0001' : 'TEST0000001');
  late List<MethodCall> calls;
  late List<Uint8List> reads;
  late String serial;
  late bool loseClosingReply;
  late TremolPeer tremol;
  late FiscalPeer datecs;
  late int handle;
  Future<Object?> answer(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'open':
        return ++handle;
      case 'openCandidate':
        return ++handle;
      case 'bindCandidate':
      case 'close':
        return null;
      case 'read':
        if (reads.isEmpty) throw PlatformException(code: 'DISCONNECT');
        return reads.removeAt(0);
      case 'write':
        final bytes = (call.arguments as Map)['bytes'] as Uint8List;
        late final List<int> reply;
        if (bytes.first == 1) {
          reply = await datecs.exchange(
            bytes,
            DatecsGatewayProtocol.frameLength,
          );
        } else if (bytes.length > 3 && bytes[3] == 0x60) {
          reply = TremolProtocol.encode(
            bytes[2],
            bytes[3],
            ascii.encode(serial),
          );
        } else {
          reply = await tremol.exchange(bytes, TremolProtocol.frameLength);
        }
        if (loseClosingReply &&
            bytes.first == 1 &&
            datecs.commands.last == 56) {
          return null;
        }
        if (bytes.first == 1) reads.add(Uint8List.fromList([0x16]));
        reads.add(Uint8List(0)); // USB FTDI modem-status-only packet.
        reads.add(Uint8List.fromList(reply.take(1).toList()));
        if (reply.length > 1) reads.add(Uint8List.fromList(reply.sublist(1)));
        return null;
      default:
        fail('unexpected transport call ${call.method}');
    }
  }

  setUp(() {
    calls = [];
    reads = [];
    serial = 'TEST0000001';
    loseClosingReply = false;
    tremol = TremolPeer();
    datecs = FiscalPeer()..romanian = true;
    handle = 0;
    messenger.setMockMethodCallHandler(channel, answer);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Map<String, dynamic> settings(String model, String transport) => {
    'model': model,
    'transport': transport,
    'deviceId': transport == 'usb' ? usbId(model) : mac,
    'baudRate': '115200',
    'operator': '1',
    'password': '0001',
    'cashCode': '0',
    'cardCode': '1',
    'host': '192.168.6.70',
    'port': '8000',
  };

  for (final transport in ['usb', 'bluetooth']) {
    for (final model in FiscalModel.values) {
      test(
        '$model receives production status and closes a cash receipt over $transport',
        () async {
          final device = FiscalDevice.fromSettings(
            settings(model.name, transport),
          );
          expect((await device.readStatus()).ready, true);
          final result = await device.receipt(
            FiscalReceipt(
              commandId: 'selected-register',
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
            ),
          );
          expect(
            result.outcome,
            CommandOutcome.succeeded,
            reason: result.message,
          );
          final opens = calls.where((call) => call.method == 'open');
          expect(opens.length, greaterThanOrEqualTo(2));
          for (final call in opens) {
            expect(call.arguments, {
              'transport': transport,
              'id': transport == 'usb' ? usbId(model.name) : mac,
              'baudRate': 115200,
            });
          }
          expect(
            calls.where((call) => call.method == 'close').length,
            opens.length,
          );
          expect(
            model == FiscalModel.datecsDp25
                ? datecs.commands.where((c) => c == 56).length
                : tremol.commands.where((c) => c == 0x38).length,
            1,
          );
        },
      );
    }
  }

  test(
    'lost MX closure reply remains unknown with one write to the chosen register',
    () async {
      loseClosingReply = true;
      final device = FiscalDevice.fromSettings(settings('datecsDp25', 'usb'));
      final result = await device.receipt(
        FiscalReceipt(
          commandId: 'lost',
          currency: 'RON',
          totalMinor: 2000,
          lines: [
            FiscalLine(
              name: 'Cafea',
              quantityDecimal: '1',
              unitPriceMinor: 2000,
              grossTotalMinor: 2000,
              vatGroup: 'A',
            ),
          ],
          paymentMethod: FiscalPaymentMethod.cash,
        ),
      );
      expect(result.outcome, CommandOutcome.unknown);
      expect(datecs.commands.where((c) => c == 56).length, 1);
      expect(calls.last.method, 'close');
    },
  );

  test(
    'USB without a serial descriptor binds the ECR identity and refuses a replacement',
    () async {
      final key = await FiscalByteSession.bindUsb(
        '/dev/fixture',
        model: FiscalModel.tremolFp21,
        baudRate: 115200,
      );
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      final endpoint = FiscalSerialEndpoint(
        transport: 'usb',
        deviceId: key,
        model: FiscalModel.tremolFp21,
      );
      final first = await FiscalByteSession.connect(endpoint);
      await first.close();
      serial = 'TEST0000002';
      calls.clear();
      await expectLater(FiscalByteSession.connect(endpoint), throwsStateError);
      final writes = calls
          .where((c) => c.method == 'write')
          .map((c) => c.arguments['bytes'] as Uint8List);
      expect(writes.map((v) => v.length == 1 ? v.first : v[3]).toList(), [
        9,
        0x60,
      ]);
      expect(calls.last.method, 'close');
    },
  );

  test(
    'FP21 binds and reopens an unpadded ten-byte manufacturing serial',
    () async {
      serial = 'AB00000423';
      final id = await FiscalByteSession.bindUsb(
        '/dev/fixture',
        model: FiscalModel.tremolFp21,
        baudRate: 115200,
      );
      expect(id, key('tremolFp21', serial));
      final endpoint = FiscalSerialEndpoint(
        transport: 'usb',
        deviceId: id,
        model: FiscalModel.tremolFp21,
      );
      await (await FiscalByteSession.connect(endpoint)).close();
      serial = 'AB00000424';
      await expectLater(FiscalByteSession.connect(endpoint), throwsStateError);
      expect(calls.last.method, 'close');
    },
  );

  test(
    'invalid or wrong-model 60h replies never create a USB binding',
    () async {
      for (final (model, value) in [
        (FiscalModel.tremolM20, 'AB00000423'),
        for (final bad in [
          '',
          'AB00000000',
          '00000000000',
          '-----------',
          '1234567890',
          'ab00000423',
          'AB0000042X',
          'AB00000423 ',
        ])
          (FiscalModel.tremolFp21, bad),
      ]) {
        serial = value;
        await expectLater(
          FiscalByteSession.bindUsb(
            '/dev/fixture',
            model: model,
            baudRate: 115200,
          ),
          throwsFormatException,
        );
        expect(calls.last.method, 'close');
      }
      expect(calls.where((call) => call.method == 'bindCandidate'), isEmpty);
    },
  );

  for (final transport in ['usb', 'bluetooth']) {
    test(
      'explicit legacy ROU uses $transport for setup, status, VAT, sale and report',
      () async {
        final operations = <String>[];
        final state = settings('datecsDp25', transport)
          ..addAll({
            'datecsProfile': 'legacyRou',
            'cashCode': 'P',
            'cardCode': 'D',
          });
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'legacyBind') return usbId('datecsDp25');
          expect(call.method, 'legacyOperation');
          final args = Map<String, dynamic>.from(call.arguments as Map);
          expect(args['transport'], transport);
          expect(args['id'], state['deviceId']);
          expect(args.containsKey('host'), false);
          operations.add(args['operation'] as String);
          return switch (args['operation']) {
            'status' => {
              'ready': true,
              'protocolConfirmed': true,
              'description': 'pregătit',
            },
            'readVatRates' => {
              'enabled': '1100',
              'decimals': '2',
              'rates': ['21.00', '11.00', '0.00', '0.00'],
            },
            'receipt' => {'outcome': 'succeeded', 'reference': '101'},
            'xReport' => {'outcome': 'succeeded'},
            _ => throw StateError('Unexpected terminal operation'),
          };
        });
        if (transport == 'usb') {
          expect(
            await FiscalByteSession.bindUsb(
              '/dev/test',
              model: FiscalModel.datecsDp25,
              baudRate: 115200,
              legacyDatecs: true,
            ),
            state['deviceId'],
          );
        }
        final device = FiscalDevice.fromSettings(state);
        expect((await device.readStatus()).ready, true);
        expect(await device.readVatRates(), {'A': 21.0, 'B': 11.0});
        expect(
          (await device.receipt(
            FiscalReceipt(
              commandId: 'original',
              currency: 'RON',
              totalMinor: 500,
              paymentMethod: FiscalPaymentMethod.card,
              confirmedPaymentReference: 'TEST',
              lines: [
                FiscalLine(
                  name: 'Cafea',
                  quantityDecimal: '1',
                  unitPriceMinor: 500,
                  grossTotalMinor: 500,
                  vatGroup: 'A',
                ),
              ],
            ),
          )).reference,
          '101',
        );
        expect(
          (await device.report(closeDay: false)).outcome,
          CommandOutcome.succeeded,
        );
        expect(operations.where((op) => op == 'receipt').length, 1);
        expect(operations.where((op) => op == 'xReport').length, 1);
      },
    );
  }

  test(
    'serial Datecs auto probe never falls back to the legacy protocol',
    () async {
      final endpoint = FiscalEndpoint.fromSettings(
        settings('datecsDp25', 'bluetooth'),
      );
      final client = DatecsDeviceClient(
        endpoint,
        sessions: (_) => throw StateError('offline'),
        legacyProbe: () => fail('legacy network probe'),
      );
      expect((await client.inspect()).ready, false);
    },
  );
}
