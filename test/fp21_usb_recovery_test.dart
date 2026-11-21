import 'dart:convert';
import 'dart:io';

import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/fp21_test_receipt.dart';
import 'package:chimera_companion/hardware/fp21_usb.dart';
import 'package:chimera_companion/hardware/tremol_adapter.dart'
    show TremolPaperRequired;
import 'package:chimera_companion/hardware/tremol_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const selected = 'serial-port';
  const device = 'fp21-usb:$selected';
  const sample = 'usb-test-1795079700000000-123';
  late Directory directory;
  late File journalFile;
  late Fp21Usb usb;
  final opens = <String?>[];
  final commands = <int>[];
  final responses = <List<int>>[];
  final status = [0, 0, 1, 0, 0, 0, 0];
  var runtimeStatus = 0x40;
  bool loseAcknowledge = false;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> record({
    String id = sample,
    String owner = device,
    String operation = 'nonFiscal',
    String outcome = 'unknown',
    DateTime? at,
    String? hash,
    String message =
        'Tipărire întreruptă (cod 04). Verifică hârtia și documentul pe imprimantă.',
  }) async {
    final row = {
      'id': id,
      'deviceId': owner,
      'operation': operation,
      'outcome': outcome,
      // Persisted hash from the v1 sample for this device and operator 20.
      'hash':
          hash ??
          '39d0a72c44ec225e634c25f0188724128b6508b53f3648b67b4deac6f58e516d',
      'at': (at ?? DateTime.now()).toUtc().toIso8601String(),
      'message': message,
    };
    await journalFile.writeAsString(
      '${jsonEncode(row)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('usb-fp21-finish-');
    journalFile = File('${directory.path}/journal');
    usb = Fp21Usb(journal: CommandJournal(journalFile));
    opens.clear();
    commands.clear();
    responses.clear();
    status.setAll(0, [0, 0, 1, 0, 0, 0, 0]);
    runtimeStatus = 0x40;
    loseAcknowledge = false;
    messenger.setMockMethodCallHandler(Fp21Usb.channel, (call) async {
      if (call.method == 'open') {
        expect(call.arguments['id'], selected);
        opens.add(call.arguments['purpose'] as String?);
        return 21;
      }
      expect(call.arguments['session'], 21);
      if (call.method == 'close') return null;
      if (call.method == 'read') {
        return Uint8List.fromList(responses.removeAt(0));
      }
      expect(call.method, 'write');
      final bytes = call.arguments['bytes'] as Uint8List;
      if (bytes.length == 1) {
        expect(bytes.single, 9);
        responses.add([runtimeStatus]);
        return null;
      }
      final seq = bytes[2], command = bytes[3];
      commands.add(command);
      if (command == 0x20) {
        responses.add(TremolProtocol.encode(seq, command, status));
      } else if (command == 0x21) {
        expect(opens.last, isNull);
        responses.add(
          TremolProtocol.encode(seq, command, ascii.encode('FP21')),
        );
      } else if (opens.last == 'nonFiscalTest') {
        expect(command, 0x2e);
        status[2] |= 1;
        throw PlatformException(code: 'USB_READ');
      } else {
        expect(
          opens.last,
          isIn(['finishNonFiscalTest', 'closeNonFiscalTest', 'cutPaper']),
        );
        if (opens.last == 'cutPaper') {
          expect(command, 0x29);
          expect(bytes.sublist(4, bytes.length - 3), isEmpty);
        }
        if (opens.last == 'closeNonFiscalTest') expect(command, 0x2f);
        expect(command, isNot(0x2e));
        if (loseAcknowledge) throw PlatformException(code: 'USB_READ');
        final sum = seq ^ 0x30 ^ 0x30;
        responses.add([
          6,
          seq,
          0x30,
          0x30,
          0x30 + (sum >> 4),
          0x30 + (sum & 15),
          10,
        ]);
        if (command == 0x2f) status[2] &= ~1;
      }
      return null;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(Fp21Usb.channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'recognizes the original v1 sample and finishes once across a restart',
    () async {
      // Physical non-fiscal-open FP21: runtime 09h ready, no customer display.
      status.setAll(0, [0x80, 0x80, 0x81, 0xd0, 0xa9, 0x80, 0x80]);
      await record();
      await record(id: 'another-device', owner: 'fp21-usb:other');
      final probe = await usb.probe(selected);
      expect(probe.details['interruptedTestId'], sample);
      expect(probe.description, contains('04'));
      final result = await usb.finishInterruptedTest(selected, sample);
      expect(result.outcome, CommandOutcome.succeeded);
      expect(commands.where((cmd) => cmd == 0x2f), hasLength(1));
      final reopened = Fp21Usb(journal: CommandJournal(journalFile));
      expect(
        (await reopened.finishInterruptedTest(selected, sample)).outcome,
        CommandOutcome.succeeded,
      );
      expect(opens, [null, 'finishNonFiscalTest']);
    },
  );

  test(
    'unknown native-symbol progress allows only closing the open sample',
    () async {
      status[2] = 0;
      final result = await usb.printTest(
        selected,
        commandId: sample,
        operatorNumber: 20,
        operatorPassword: '1234',
      );
      expect(result.outcome, CommandOutcome.unknown);
      final log = CommandJournal(journalFile);
      expect(
        (await log.latestDeviceCommands(device)).first['hash'],
        CommandJournal.fingerprint(device, 'nonFiscal', {
          'operatorNumber': 20,
          'lines': fp21TestReceiptLines,
          'ean13': fp21TestReceiptBarcode,
          'qrUrl': 'https://chimeraerp.ro',
          'footer': fp21TestReceiptFooter,
        }),
      );

      final restarted = Fp21Usb(journal: log);
      final probe = await restarted.probe(selected);
      expect(probe.details['canCloseTestId'], sample);
      expect(probe.details['interruptedTestId'], isNull);
      expect(
        (await restarted.finishInterruptedTest(selected, sample)).outcome,
        CommandOutcome.rejected,
      );
      expect(opens, ['nonFiscalTest', null]);
      expect(
        (await restarted.closeInterruptedTest(selected, sample)).outcome,
        CommandOutcome.succeeded,
      );
      expect(commands.where((cmd) => cmd != 0x20), [0x2e, 0x2f]);
    },
  );

  test(
    'a lost recovery acknowledgement prevents resuming the same tail twice',
    () async {
      await record();
      loseAcknowledge = true;
      expect(
        (await usb.finishInterruptedTest(selected, sample)).outcome,
        CommandOutcome.unknown,
      );
      final writesBefore = List.of(commands);
      expect(
        (await usb.finishInterruptedTest(selected, sample)).outcome,
        CommandOutcome.unknown,
      );
      expect(commands, writesBefore);
      expect(
        (await usb.probe(selected)).details.containsKey('interruptedTestId'),
        isFalse,
      );
    },
  );

  test(
    'rejects a stale, foreign, unfinished, or nonmatching latest sample before opening USB',
    () async {
      for (final variant in [
        'old',
        'future',
        'hash',
        'id',
        'owner',
        'in_flight',
        'succeeded',
        'operation',
        'superseded',
      ]) {
        if (await journalFile.exists()) await journalFile.delete();
        final now = DateTime.now();
        await record(
          at: variant == 'old'
              ? now.subtract(const Duration(hours: 7))
              : variant == 'future'
              ? now.add(const Duration(hours: 1))
              : now,
          hash: variant == 'hash' ? 'invalid' : null,
          id: variant == 'id' ? 'other-usb-test' : sample,
          owner: variant == 'owner' ? 'fp21-usb:other' : device,
          outcome: ['in_flight', 'succeeded'].contains(variant)
              ? variant
              : 'unknown',
          operation: variant == 'operation' ? 'fiscalReceipt' : 'nonFiscal',
        );
        if (variant == 'superseded') {
          await record(id: 'second-command', operation: 'xReport');
        }
        expect(
          (await usb.finishInterruptedTest(selected, sample)).outcome,
          CommandOutcome.rejected,
          reason: variant,
        );
      }
      expect(opens, isEmpty);
    },
  );

  test(
    'a fiscal or closed document on the second status read never receives paper commands',
    () async {
      await record();
      expect((await usb.probe(selected)).details['interruptedTestId'], sample);
      status[2] = 2;
      expect(
        (await usb.finishInterruptedTest(selected, sample)).outcome,
        CommandOutcome.rejected,
      );
      expect(commands.every((command) => command == 0x20), isTrue);
    },
  );

  test(
    'close-only sends only the close after status and never repeats across restart',
    () async {
      await record();
      expect((await usb.probe(selected)).details['canCloseTestId'], sample);
      commands.clear();
      final result = await usb.closeInterruptedTest(selected, sample);
      expect(result.outcome, CommandOutcome.succeeded);
      expect(commands.where((command) => command != 0x20), [0x2f]);
      final reopened = Fp21Usb(journal: CommandJournal(journalFile));
      expect(
        (await reopened.closeInterruptedTest(selected, sample)).outcome,
        CommandOutcome.succeeded,
      );
      expect(opens, [null, 'closeNonFiscalTest']);
    },
  );

  test(
    'close-only becomes available after an uncertain tail, and is suppressed after an uncertain close',
    () async {
      await record();
      loseAcknowledge = true;
      expect(
        (await usb.finishInterruptedTest(selected, sample)).outcome,
        CommandOutcome.unknown,
      );
      final statusAfterTail = await usb.probe(selected);
      expect(statusAfterTail.details['interruptedTestId'], isNull);
      expect(statusAfterTail.details['canCloseTestId'], sample);
      expect(
        (await usb.closeInterruptedTest(selected, sample)).outcome,
        CommandOutcome.unknown,
      );
      expect((await usb.probe(selected)).details['canCloseTestId'], isNull);
      final writesBefore = commands.length;
      expect(
        (await usb.closeInterruptedTest(selected, sample)).outcome,
        CommandOutcome.unknown,
      );
      expect(commands, hasLength(writesBefore));
    },
  );

  test(
    'refused finish can be closed only with the original sample and exact follow-up hash',
    () async {
      for (final kind in [
        'missing',
        'stale',
        'foreign',
        'unrelated',
        'done',
        'id',
        'hash',
        'valid',
      ]) {
        if (await journalFile.exists()) await journalFile.delete();
        if (kind != 'missing') {
          await record(
            owner: kind == 'foreign' ? 'fp21-usb:other' : device,
            at: kind == 'stale'
                ? DateTime.now().subtract(const Duration(hours: 7))
                : null,
          );
        }
        if (kind == 'unrelated') await record(id: 'some-other-command');
        await record(
          id: kind == 'id' ? 'fp21-finish-unrelated' : 'fp21-finish-$sample',
          operation: 'finishNonFiscalTest',
          outcome: kind == 'done' ? 'succeeded' : 'rejected',
          hash: CommandJournal.fingerprint(device, 'finishNonFiscalTest', {
            'originalCommandId': kind == 'hash' ? 'another' : sample,
          }),
        );
        final expected = kind == 'valid' ? sample : null;
        expect(
          (await usb.probe(selected)).details['canCloseTestId'],
          expected,
          reason: kind,
        );
        final result = await usb.closeInterruptedTest(selected, sample);
        expect(
          result.outcome,
          expected == null ? CommandOutcome.rejected : CommandOutcome.succeeded,
          reason: kind,
        );
      }
      expect(
        opens.where((purpose) => purpose == 'closeNonFiscalTest'),
        hasLength(1),
      );
    },
  );

  test(
    'close-only rejects fiscal, closed or paper-blocked equipment on dispatch',
    () async {
      for (final flags in [
        [0, 2],
        [0, 3],
        [0, 0],
        [1, 1],
      ]) {
        if (await journalFile.exists()) await journalFile.delete();
        await record();
        status[1] = flags[0];
        status[2] = flags[1];
        expect((await usb.probe(selected)).details['canCloseTestId'], isNull);
        expect(
          (await usb.closeInterruptedTest(selected, sample)).outcome,
          CommandOutcome.rejected,
        );
      }
      expect(commands.toSet(), {0x20, 0x21});
      expect(commands.where((cmd) => cmd == 0x21), hasLength(1));
    },
  );

  test(
    'a refused A2 close requires the same open sample and a connected display',
    () async {
      await record();
      await record(
        id: 'fp21-finish-$sample',
        operation: 'finishNonFiscalTest',
        hash: CommandJournal.fingerprint(device, 'finishNonFiscalTest', {
          'originalCommandId': sample,
        }),
      );
      await record(
        id: 'fp21-close-$sample',
        operation: 'closeNonFiscalTest',
        hash: CommandJournal.fingerprint(device, 'closeNonFiscalTest', {
          'originalCommandId': sample,
        }),
        message:
            'Închidere neconfirmată de FP21 (cod A2). Verifică starea imprimantei.',
      );
      status[4] = 8;
      expect((await usb.probe(selected)).description, contains('A2'));
      expect((await usb.probe(selected)).details['canCloseTestId'], isNull);
      expect(
        (await usb.closeInterruptedTest(selected, sample)).outcome,
        CommandOutcome.rejected,
      );
      expect(commands.where((cmd) => cmd != 0x20), isEmpty);
      status[4] = 0;
      expect((await usb.probe(selected)).details['canCloseTestId'], sample);
      expect(
        (await usb.closeInterruptedTest(selected, sample)).outcome,
        CommandOutcome.succeeded,
      );
      expect(
        (await usb.closeInterruptedTest(selected, sample)).outcome,
        CommandOutcome.succeeded,
      );
      expect(commands.where((cmd) => cmd != 0x20), [0x2f]);
      expect((await usb.probe(selected)).details['canCloseTestId'], isNull);
    },
  );
  test(
    'operator can close a reconnected FP21 after power loss with no previous journal rows',
    () async {
      status.setAll(0, [0x82, 0x80, 0x81, 0xd0, 0xa1, 0x80, 0x80]);
      expect(
        (await usb.forceCloseNonFiscal(selected, 'operator-close')).outcome,
        CommandOutcome.succeeded,
      );
      expect(commands, [0x20, 0x2f, 0x20]);
      expect(opens, ['closeNonFiscalTest']);
      expect(
        (await Fp21Usb(
          journal: CommandJournal(journalFile),
        ).forceCloseNonFiscal(selected, 'operator-close')).outcome,
        CommandOutcome.succeeded,
      );
      expect(commands, [0x20, 0x2f, 0x20]);

      final probe = await usb.probe(selected);
      expect(probe.details['statusBytes'], '82 80 80 d0 a1 80 80');
      expect(probe.details['nonFiscalOpen'], isFalse);
      expect(probe.details['fiscalOpen'], isFalse);
      expect(probe.ready, isTrue);
      expect(probe.description.toLowerCase(), contains('alimentar'));
      expect(commands, [0x20, 0x2f, 0x20, 0x20, 0x21]);
      expect(opens, ['closeNonFiscalTest', null]);
    },
  );

  test('an idle status cannot override a live paper fault', () async {
    status.setAll(0, [0x82, 0x80, 0x80, 0xd0, 0xa1, 0x80, 0x80]);
    runtimeStatus = 0x42;
    await expectLater(usb.probe(selected), throwsA(isA<TremolPaperRequired>()));
    expect(commands, isEmpty);
  });

  for (final (condition, byte, mask) in [
    ('open non-fiscal receipt', 2, 0x01),
    ('open fiscal receipt', 2, 0x02),
    ('paper out', 1, 0x01),
    ('another blocking ST0 flag', 0, 0x04),
  ]) {
    test('a latched power interruption cannot mask $condition', () async {
      status.setAll(0, [0x82, 0x80, 0x80, 0xd0, 0xa1, 0x80, 0x80]);
      status[byte] |= mask;
      final probe = await usb.probe(selected);
      expect(probe.ready, isFalse);
      expect(probe.details['canFinishNonFiscal'], isFalse);
      expect(commands, [0x20]);
    });
  }

  test(
    'operator cut is a distinct command and an ambiguous response cannot cut twice',
    () async {
      status.setAll(0, [0x80, 0x80, 0x80, 0xd0, 0xa1, 0x80, 0x80]);
      expect(
        (await usb.cutPaper(selected, 'operator-cut-1')).outcome,
        CommandOutcome.succeeded,
      );
      expect(commands.where((c) => c != 0x20), [0x29]);
      expect(opens, ['cutPaper']);
      await expectLater(
        usb.forceCloseNonFiscal(selected, 'operator-cut-1'),
        throwsStateError,
      );
      loseAcknowledge = true;
      expect(
        (await usb.cutPaper(selected, 'operator-cut-2')).outcome,
        CommandOutcome.unknown,
      );
      final dispatched = commands.length;
      expect(
        (await Fp21Usb(
          journal: CommandJournal(journalFile),
        ).cutPaper(selected, 'operator-cut-2')).outcome,
        CommandOutcome.unknown,
      );
      expect(commands, hasLength(dispatched));
      expect(commands.where((c) => c != 0x20), [0x29, 0x29]);
    },
  );

  test('operator maintenance preserves an active fiscal document', () async {
    status[2] = 2;
    expect(
      (await usb.forceCloseNonFiscal(selected, 'close-active-fiscal')).outcome,
      CommandOutcome.rejected,
    );
    expect(
      (await usb.cutPaper(selected, 'cut-active-fiscal')).outcome,
      CommandOutcome.rejected,
    );
    expect(commands.every((c) => c == 0x20), isTrue);
  });

  test('corrupt journal denies completion before USB dispatch', () async {
    await record();
    await journalFile.writeAsString('bad row\n', mode: FileMode.append);
    await expectLater(
      usb.finishInterruptedTest(selected, sample),
      throwsFormatException,
    );
    expect(opens, isEmpty);
  });
}
