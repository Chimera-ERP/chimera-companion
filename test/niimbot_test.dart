import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/printing/niimbot_protocol.dart';
import 'package:chimera_companion/printing/niimbot_ble.dart';
import 'package:chimera_companion/printing/production_print.dart';
import 'package:chimera_companion/hardware/command_executor.dart';
import 'package:chimera_companion/hardware/command_journal.dart';

class FakeLink implements NiimbotLink {
  final stream = StreamController<List<int>>.broadcast(sync: true);
  final sent = <NiimbotPacket>[];
  int model = 4096;
  int? reject;
  @override
  Stream<List<int>> get notifications => stream.stream;
  @override
  Future<void> write(List<int> bytes) async {
    final p = NiimbotDecoder().add(bytes).single;
    sent.add(p);
    if (p.command == reject) {
      stream.add(NiimbotPacket(0xdb, [2]).encode());
      return;
    }
    final responses = {
      0xc1: 0xc2,
      0x40: 0x48,
      0x21: 0x31,
      0x23: 0x33,
      1: 2,
      3: 4,
      0x13: 0x14,
      0x20: 0x30,
      0x15: 0x16,
      0xe3: 0xe4,
      0xa3: 0xb3,
      0xf3: 0xf4,
    };
    if (responses[p.command] case final int command) {
      final reply = NiimbotPacket(
        command,
        p.command == 0x40
            ? niimbotU16(model)
            : p.command == 0xa3
            ? [0, 1, 100, 100]
            : [1],
      ).encode();
      stream.add(reply.sublist(0, 3));
      stream.add(reply.sublist(3));
    }
  }

  @override
  Future<void> close() => stream.close();
}

Map<String, dynamic> config() => {
  'name': 'B1',
  'protocol': 'niimbot',
  'host': 'ble:AA:BB:CC:DD:EE:FF',
  'port': 0,
  'widthDots': 384,
  'heightDots': 800,
  'modelId': 4096,
};
Map<String, dynamic> job() => {
  'version': 1,
  'commandId': 'print-1',
  'operation': 'productionLabel',
  'printerId': 'printer:ble:AA:BB:CC:DD:EE:FF:0',
  'operationId': 'operation-1',
  'product': 'Cafea',
  'lot': 'LOT-001',
  'quantity': '1.5',
  'unit': 'kg',
  'producedAt': '2026-10-22T08:00:00Z',
  'expiresAt': null,
  'provisional': false,
  'reprintOf': null,
  'reprintReason': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'known frame, fragmented/concatenated frames and corrupt checksum recovery',
    () {
      expect(NiimbotPacket(0xc1, [1]).encode(), [
        3,
        85,
        85,
        193,
        1,
        1,
        193,
        170,
        170,
      ]);
      final decoder = NiimbotDecoder();
      final frame = NiimbotPacket(0x48, [16, 0]).encode();
      expect(decoder.add(frame.sublist(0, 5)), isEmpty);
      expect(decoder.add(frame.sublist(5)).single.data, [16, 0]);
      final corrupt = [...frame]..[6] = 0;
      expect(decoder.add([...corrupt, ...frame, ...frame]).length, 2);
    },
  );
  test('bitmap row counts and empty rows follow protocol', () {
    expect(niimbotRow(258, [0, 0], 384).data, [1, 2, 1]);
    final row = niimbotRow(0, [
      255,
      ...List.filled(15, 0),
      128,
      ...List.filled(31, 0),
    ], 384);
    expect(row.command, 0x85);
    expect(row.data.take(6), [0, 0, 8, 1, 0, 1]);
  });
  test(
    'identification only reads and unsupported model fails without printing',
    () async {
      final link = FakeLink(), session = NiimbotSession(FakeLink());
      await session.close();
      final probe = NiimbotSession(link);
      expect((await probe.identify()).name, 'B1');
      expect(link.sent.map((p) => p.command), [0xc1, 0x40]);
      link.model = 65535;
      await expectLater(probe.identify(), throwsUnsupportedError);
      expect(link.sent.every((p) => [0xc1, 0x40].contains(p.command)), isTrue);
      await probe.close();
    },
  );
  for (final id in [4096, 2304]) {
    test('model $id acknowledged single-page flow', () async {
      final link = FakeLink()..model = id;
      final session = NiimbotSession(link), model = NiimbotModel.fromId(id);
      await session.printBitmap(
        model,
        model.width,
        1,
        List.filled(model.width ~/ 8, 128),
      );
      expect(link.sent.where((p) => p.command == 1).length, 1);
      expect(link.sent.firstWhere((p) => p.command == 0x13).data, [
        0,
        1,
        ...niimbotU16(model.width),
        if (model.b1) ...[0, 1],
      ]);
      expect(link.sent.last.command, 0xf3);
      await session.close();
    });
  }
  test(
    'rejection stops sequence without retry, cancellation or fake success',
    () async {
      final link = FakeLink()..reject = 0xe3;
      final session = NiimbotSession(link);
      await expectLater(
        session.printBitmap(
          NiimbotModel.fromId(4096),
          384,
          1,
          List.filled(48, 0),
        ),
        throwsStateError,
      );
      expect(link.sent.last.command, 0xe3);
      expect(link.sent.where((p) => p.command == 1).length, 1);
      await session.close();
    },
  );
  test('config rejects invalid BLE identity, model and dimensions', () {
    for (final changes in [
      {'host': 'ble:garbage'},
      {'port': 9100},
      {'modelId': 999},
      {'widthDots': 385},
      {'heightDots': 0},
    ]) {
      expect(
        () => PrinterConfig.fromJson({...config(), ...changes}),
        throwsA(anyOf(isA<FormatException>(), isA<UnsupportedError>())),
      );
    }
  });
  test(
    'BLE uses same authorization, durable idempotency and recovery',
    () async {
      final dir = await Directory.systemTemp.createTemp('niimbot-test-');
      addTearDown(() => dir.delete(recursive: true));
      final journal = CommandJournal(File('${dir.path}/journal'));
      var sends = 0;
      final printer = ProductionPrinter(
        executor: HardwareCommandExecutor(),
        journal: journal,
        send: (_, bytes) async {
          expect(utf8.decode(bytes), contains('LOT-001'));
          sends++;
        },
      );
      final cfg = PrinterConfig.fromJson(config()),
          payload = ProductionPrintJob(job());
      await expectLater(
        printer.execute(
          cfg,
          payload,
          authorize: () async {
            throw StateError('denied');
          },
        ),
        throwsStateError,
      );
      expect(sends, 0);
      for (var i = 0; i < 2; i++) {
        await printer.execute(cfg, payload, authorize: () async {});
      }
      expect(sends, 1);
      await expectLater(
        printer.execute(
          cfg,
          ProductionPrintJob({...job(), 'quantity': '2'}),
          authorize: () async {},
        ),
        throwsStateError,
      );
      expect(sends, 1);
    },
  );
  testWidgets(
    'raster has bounded packed pixels; undersized labels reject rather than truncate',
    (tester) async {
      final cfg = PrinterConfig.fromJson(config());
      final pixels = await tester.runAsync(() => niimbotRaster(cfg, 'TEST'));
      expect(pixels!.length, 384 ~/ 8 * 800);
      expect(pixels.any((p) => p != 0), isTrue);
      await expectLater(
        niimbotRaster(
          PrinterConfig.fromJson({...config(), 'heightDots': 64}),
          'TEST\n' * 40,
        ),
        throwsFormatException,
      );
    },
  );
}
