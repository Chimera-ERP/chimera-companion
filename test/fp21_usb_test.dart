import 'dart:convert';
import 'dart:io';

import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/fp21_test_receipt.dart';
import 'package:chimera_companion/hardware/fp21_usb.dart';
import 'package:chimera_companion/hardware/tremol_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const usb = Fp21Usb();
  final writes = <List<int>>[];
  final calls = <String>[];
  final packets = <List<int>>[];
  var denied = false;
  var corrupt = false;
  var statusFlag = 0;
  var versionData = <int>[];
  var versionRefused = false;

  setUp(() {
    writes.clear();
    calls.clear();
    packets.clear();
    denied = false;
    corrupt = false;
    statusFlag = 0;
    versionData = ascii.encode('FP21;RO;4.10');
    versionRefused = false;
    messenger.setMockMethodCallHandler(Fp21Usb.channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'open':
          expect(call.arguments['id'], 'chosen-port');
          if (denied) throw PlatformException(code: 'USB_PERMISSION');
          return 42;
        case 'read':
          expect(call.arguments['session'], 42);
          return Uint8List.fromList(packets.removeAt(0));
        case 'write':
          expect(call.arguments['session'], 42);
          final request = call.arguments['bytes'] as Uint8List;
          writes.add(request);
          if (request.length == 1) {
            expect(request.single, 9);
            if (packets.isEmpty) packets.add([0x40]);
          } else {
            final seq = request[2], cmd = request[3];
            expect(cmd, isIn([0x20, 0x21]));
            expect(request, TremolProtocol.encode(seq, cmd, []));
            if (cmd == 0x21 && versionRefused) {
              final checksum = seq ^ 0x30 ^ 0x31;
              packets.add([
                6,
                seq,
                0x30,
                0x31,
                0x30 + (checksum >> 4),
                0x30 + (checksum & 15),
                10,
              ]);
              return null;
            }
            final frame = TremolProtocol.encode(
              seq,
              cmd,
              cmd == 0x21 ? versionData : [statusFlag, 0, 0, 0, 0, 0, 0],
            );
            if (corrupt) frame[4] ^= 1;
            packets.addAll([
              frame.sublist(0, 2),
              frame.sublist(2, 7),
              if (frame.length > 7) frame.sublist(7),
            ]);
          }
          return null;
        case 'close':
          expect(call.arguments['session'], 42);
          return null;
        default:
          fail('Unexpected USB operation: ${call.method}');
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(Fp21Usb.channel, null));

  test(
    'fragmented FP21 reply confirms communication with a busy printer',
    () async {
      statusFlag = 1;
      packets.addAll([
        [0x41],
        [0x40],
      ]);
      final status = await usb.probe('chosen-port');
      expect(status.ready, isFalse);
      expect(status.details['statusBytes'], '01 00 00 00 00 00 00');
      expect(writes.length, 3);
      expect(writes.take(2).toList(), [
        [9],
        [9],
      ]);
      final firstSequence = writes.last[2];
      statusFlag = 0;
      packets.add([0x40]);
      expect((await usb.probe('chosen-port')).ready, isTrue);
      expect(writes.last[2], isNot(firstSequence));
      expect(calls.last, 'close');
    },
  );

  test(
    'corrupt USB response fails and releases handle without retry',
    () async {
      corrupt = true;
      packets.add([0x40]);
      await expectLater(usb.probe('chosen-port'), throwsFormatException);
      expect(writes.length, 2);
      expect(calls.last, 'close');
    },
  );

  test('ready probe appends the sanitized firmware from 21h', () async {
    versionData = [
      ...ascii.encode(' FP21;RO'),
      0,
      10,
      0x1b,
      ...ascii.encode(' Build 17   '),
    ];
    final status = await usb.probe('chosen-port');
    expect(status.ready, isTrue);
    expect(status.description, contains('FP21;RO Build 17'));
    expect(status.details['firmware'], 'FP21;RO Build 17');
    expect(writes.where((w) => w.length > 1).map((w) => w[3]), [0x20, 0x21]);
  });

  test(
    'unsupported or malformed firmware preserves the confirmed status',
    () async {
      for (final value in [
        <int>[],
        List.filled(101, 65),
        ascii.encode('ignored'),
      ]) {
        versionData = value;
        versionRefused = value.length == 7;
        final status = await usb.probe('chosen-port');
        expect(status.ready, isTrue);
        expect(status.details['firmware'], isNull);
        expect(status.description, 'Tremol pregătit');
      }
    },
  );

  test('permission denial performs no USB traffic', () async {
    denied = true;
    await expectLater(
      usb.probe('chosen-port'),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, ['open']);
  });
  group('explicit non-fiscal test', () {
    late Directory directory;
    late File journalFile;
    late Fp21Usb printer;
    int? refusal;
    final eanCommand = "P;2;12;${'200000000001'.padRight(100)}";
    final qrCommand = "C;4;${'https://chimeraerp.ro'.padRight(200)}";
    var standalone = false;
    var openDocument = 0;
    var loseNextRead = false;
    int? symbolControl;
    var lostReadCode = 'USB_DISCONNECTED';
    int? documentAfterQrTimeout;
    var failPollAfterEan = false;
    final declinedSymbols = <String>{};
    String? loseSymbolAck;
    var deviceFault = 0x30;
    Future<HardwareResult> printSample() => printer.printTest(
      'chosen-port',
      operatorNumber: 2,
      operatorPassword: 'aB78',
      commandId: 'one-demo',
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('usb-fp21-');
      journalFile = File('${directory.path}/journal');
      printer = Fp21Usb(journal: CommandJournal(journalFile));
      refusal = null;
      declinedSymbols.clear();
      loseSymbolAck = null;
      standalone = false;
      openDocument = 0;
      loseNextRead = false;
      symbolControl = null;
      lostReadCode = 'USB_DISCONNECTED';
      documentAfterQrTimeout = null;
      failPollAfterEan = false;
      deviceFault = 0x30;
      messenger.setMockMethodCallHandler(Fp21Usb.channel, (call) async {
        calls.add(call.method);
        if (call.method == 'open') {
          expect(call.arguments, {
            'id': 'chosen-port',
            'purpose': standalone ? 'qrTest' : 'nonFiscalTest',
          });
          return 17;
        }
        expect(call.arguments['session'], 17);
        if (call.method == 'close') return null;
        if (call.method == 'read') {
          if (loseNextRead) {
            loseNextRead = false;
            throw PlatformException(code: lostReadCode);
          }
          return Uint8List.fromList(packets.removeAt(0));
        }
        expect(call.method, 'write');
        final frame = call.arguments['bytes'] as Uint8List;
        if (frame.length == 1) {
          expect(frame.single, 9);
          if (failPollAfterEan && writes.lastOrNull?[3] == 0x51) {
            failPollAfterEan = false;
            loseNextRead = true;
          } else {
            packets.add([0x40]);
          }
        } else {
          writes.add(frame);
          final sequence = frame[2], command = frame[3];
          if (command == 0x20) {
            packets.add(
              TremolProtocol.encode(sequence, command, [
                statusFlag,
                0,
                openDocument,
                0,
                0,
                0,
                0,
              ]),
            );
          } else {
            final symbol = command == 0x51
                ? ascii.decode(frame.sublist(4, frame.length - 3))
                : null;
            if (symbol != null && symbol == loseSymbolAck) {
              if (symbol == qrCommand && documentAfterQrTimeout != null) {
                openDocument = documentAfterQrTimeout!;
              }
              loseNextRead = true;
              return null;
            }
            if (symbol != null && symbolControl != null) {
              packets.add([symbolControl!]);
              return null;
            }
            final declined = declinedSymbols.contains(symbol);
            final error = declined
                ? 0x32
                : command == refusal
                ? 0x33
                : 0x30;
            if (error == 0x30 && command == 0x2e) openDocument = 1;
            if (error == 0x30 && command == 0x2f) openDocument = 0;
            final ste1 = declined ? deviceFault : 0x30;
            final sum = sequence ^ ste1 ^ error;
            packets.add([
              6,
              sequence,
              ste1,
              error,
              0x30 + (sum >> 4),
              0x30 + (sum & 15),
              10,
            ]);
          }
        }
        return null;
      });
    });
    tearDown(() => directory.delete(recursive: true));

    test(
      'acknowledges a single complete demo and replays its saved result',
      () async {
        expect((await printSample()).outcome, CommandOutcome.succeeded);
        final expected = [
          (0x20, ''),
          (0x2e, '2;aB78;0;0'),
          for (final row in fp21TestReceiptLines) (0x37, row),
          (0x51, eanCommand),
          (0x51, qrCommand),
          for (final row in fp21TestReceiptFooter) (0x37, row),
          (0x2f, ''),
        ];
        expect(
          writes.map((r) => (r[3], ascii.decode(r.sublist(4, r.length - 3)))),
          expected,
        );
        final firstRequestCount = calls.length;
        expect((await printSample()).outcome, CommandOutcome.succeeded);
        expect(calls, hasLength(firstRequestCount));
        expect(await journalFile.readAsString(), isNot(contains('aB78')));
      },
    );
    test(
      'busy status and explicit opening refusal cannot print a line',
      () async {
        statusFlag = 1;
        expect((await printSample()).outcome, CommandOutcome.rejected);
        expect(writes.map((r) => r[3]), [0x20]);
        statusFlag = 0;
        refusal = 0x2e;
        final result = await printer.printTest(
          'chosen-port',
          operatorNumber: 2,
          operatorPassword: 'aB78',
          commandId: 'after-fresh-probe',
        );
        expect(result.outcome, CommandOutcome.rejected);
        expect(writes.map((r) => r[3]), [0x20, 0x20, 0x2e]);
      },
    );
    for (final (which, deviceStatus) in [
      ('EAN-13', 0x36),
      ('QR', 0x3a),
      ('both', 0x30),
    ]) {
      test(
        'explicit refusal of $which reports the partial result and closes',
        () async {
          if (which != 'QR') declinedSymbols.add(eanCommand);
          if (which != 'EAN-13') declinedSymbols.add(qrCommand);
          deviceFault = deviceStatus;
          final result = await printSample();
          expect(result.outcome, CommandOutcome.rejected);
          final message = result.message;
          expect(message, contains('EAN-13'));
          expect(message, contains('QR'));
          expect(message.toLowerCase(), contains('refuz'));
          if (which != 'both') {
            expect(message.toLowerCase(), contains('accept'));
          }
          final firstSymbol = writes.indexWhere((frame) => frame[3] == 0x51);
          expect(
            writes
                .skip(firstSymbol)
                .map((r) => (r[3], ascii.decode(r.sublist(4, r.length - 3)))),
            [
              (0x51, eanCommand),
              (0x51, qrCommand),
              for (final row in fp21TestReceiptFooter) (0x37, row),
              (0x2f, ''),
            ],
          );
          final firstRequestCount = calls.length;
          expect((await printSample()).outcome, CommandOutcome.rejected);
          expect(calls, hasLength(firstRequestCount));
        },
      );
    }
    test(
      'standalone QR sends one native symbol, without a receipt or cut',
      () async {
        standalone = true;
        final result = await printer.printQrTest('chosen-port', 'one-qr');
        expect(result.outcome, CommandOutcome.succeeded);
        expect(
          writes.map((r) => (r[3], ascii.decode(r.sublist(4, r.length - 3)))),
          [(0x20, ''), (0x51, qrCommand)],
        );
        final before = List.of(calls);
        expect(
          (await printer.printQrTest('chosen-port', 'one-qr')).outcome,
          CommandOutcome.succeeded,
        );
        expect(calls, before);
      },
    );

    test('standalone QR leaves open documents untouched', () async {
      standalone = true;
      for (final state in [1, 2, 3]) {
        openDocument = state;
        writes.clear();
        final result = await printer.printQrTest('chosen-port', 'qr-$state');
        expect(result.outcome, CommandOutcome.rejected);
        expect(writes.map((r) => r[3]), [0x20]);
      }
    });

    for (final control in [0x0e, 0x15]) {
      test(
        'explicit QR control $control never dispatches another symbol',
        () async {
          standalone = true;
          symbolControl = control;
          final result = await printer.printQrTest('chosen-port', 'qr-control');
          expect(result.outcome, CommandOutcome.rejected);
          expect(writes.map((r) => r[3]), [0x20, 0x51]);
          expect(result.message, contains('QR'));
        },
      );
    }
    for (final lost in [false, true]) {
      test(
        'standalone QR distinguishes an explicit refusal from a lost ACK ($lost)',
        () async {
          standalone = true;
          if (lost) {
            loseSymbolAck = qrCommand;
          } else {
            declinedSymbols.add(qrCommand);
          }
          final expected = lost
              ? CommandOutcome.unknown
              : CommandOutcome.rejected;
          final result = await printer.printQrTest('chosen-port', 'qr-1');
          expect(result.outcome, expected);
          expect(result.message, contains('QR'));
          expect(writes.map((r) => r[3]), [0x20, 0x51]);
          printer = Fp21Usb(journal: CommandJournal(journalFile));
          final before = List.of(calls);
          expect(
            (await printer.printQrTest('chosen-port', 'qr-1')).outcome,
            expected,
          );
          expect(calls, before);
        },
      );
    }
    for (final state in [1, 2, 3, 0]) {
      test(
        'QR timeout reconciles the live receipt state $state after dispatch',
        () async {
          loseSymbolAck = qrCommand;
          lostReadCode = 'USB_READ';
          documentAfterQrTimeout = state;
          final result = await printSample();
          expect(result.outcome, CommandOutcome.unknown);
          expect(result.message, contains('QR'));
          expect(result.message, contains('USB_READ'));
          expect(result.message, contains('Acceptat: EAN-13'));
          if (state == 1) {
            expect(result.message, contains('Bon nefiscal închis.'));
          } else if (state != 0) {
            expect(result.message, isNot(contains('Bon nefiscal închis.')));
          }
          final firstSymbol = writes.indexWhere((r) => r[3] == 0x51);
          expect(writes.skip(firstSymbol).map((r) => r[3]), [
            0x51,
            0x51,
            0x20,
            if (state == 1) ...[0x2f, 0x20],
          ]);
          expect(calls.where((call) => call == 'open'), hasLength(1));
          final before = List.of(calls);
          printer = Fp21Usb(journal: CommandJournal(journalFile));
          expect((await printSample()).outcome, CommandOutcome.unknown);
          expect(calls, before);
        },
      );
    }

    test(
      'USB read timeout during the readiness poll never dispatches or reconciles QR',
      () async {
        lostReadCode = 'USB_READ';
        failPollAfterEan = true;
        final result = await printSample();
        expect(result.outcome, CommandOutcome.unknown);
        expect(result.message, contains('USB_READ'));
        final firstSymbol = writes.indexWhere((r) => r[3] == 0x51);
        expect(writes.skip(firstSymbol).map((r) => r[3]), [0x51]);
        expect(writes.where((r) => r[3] == 0x2f), isEmpty);
      },
    );

    for (final symbol in ['EAN-13', 'QR']) {
      test(
        'lost $symbol acknowledgement stops subsequent writes and survives a restart',
        () async {
          loseSymbolAck = symbol == 'EAN-13' ? eanCommand : qrCommand;
          final result = await printSample();
          expect(result.outcome, CommandOutcome.unknown);
          expect(result.message, contains(symbol));
          if (symbol == 'QR') {
            expect(result.message, contains('Acceptat: EAN-13'));
          }
          expect(writes.last[3], 0x51);
          expect(
            writes
                .where((r) => r[3] == 0x51)
                .map((r) => ascii.decode(r.sublist(4, r.length - 3))),
            [eanCommand, if (symbol == 'QR') qrCommand],
          );
          expect(calls.last, 'close');
          final firstRequestCount = calls.length;
          printer = Fp21Usb(journal: CommandJournal(journalFile));
          expect((await printSample()).outcome, CommandOutcome.unknown);
          expect(calls, hasLength(firstRequestCount));
        },
      );
    }
  });
}
