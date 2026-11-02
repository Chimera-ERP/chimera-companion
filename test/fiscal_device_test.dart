import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/fiscal_device.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/datecs_gateway_protocol.dart';
import 'package:chimera_companion/hardware/tcp_transport.dart';
import 'package:chimera_companion/hardware/datecs_receipt_recovery.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'adapters_test.dart' as fixtures;

class FiscalPeer implements ByteSession {
  final commands = <int>[];
  final payloads = <int, String>{};
  String subtotal = '20.00';
  int? loseOn;
  String serial = 'DTTEST0001';
  String documentType = '1';
  String documentNumber = '42';
  final markers = <String>[];
  int nextLine = 0;
  bool romanian = false;
  String fiscalSerial = 'FM001';
  String z = '123';
  String fiscalNumber = '1500';
  String? journalZ;
  String? typedDocument;
  bool corruptJournal = false;
  bool openDocument = false;
  final requests = <(int, String)>[];
  @override
  Future<List<int>> exchange(
    List<int> request,
    int? Function(List<int>) frameLength,
  ) async {
    final command = request
        .sublist(6, 10)
        .fold<int>(0, (n, b) => n * 16 + b - 0x30);
    commands.add(command);
    payloads[command] = ascii.decode(request.sublist(10, request.length - 6));
    requests.add((command, payloads[command]!));
    if (command == loseOn) throw StateError('Reply lost');
    if (command == 54) markers.add(payloads[command]!.split('\t').first);
    final value = switch (command) {
      123 =>
        '0\t$serial\t$fiscalSerial\t${romanian ? "SYNTHETIC SHOP\tTEST ADDRESS\tRO000000\t" : ""}',
      48 => romanian ? '0\t$documentNumber\t$z\t1499\t' : '0\t42\t',
      125 =>
        payloads[command]!.startsWith('0\t')
            ? romanian
                  ? '0\t${payloads[command]!.endsWith("\t1\t") ? typedDocument ?? documentNumber : documentNumber}\t${payloads[command]!.endsWith("\t1\t") ? journalZ ?? z : "0"}\t$fiscalNumber\t27-10-26 12:00:00\t$documentType\t${journalZ ?? z}\t'
                  : '0\t$documentNumber\t42\t27-10-26 12:00:00\t$documentType\t5\t'
            : '0\t${nextLine < markers.length ? markers[nextLine++] : "END"}\t',
      76 => '0\t${openDocument ? 1 : 0}\t',
      51 => '0\t1\t$subtotal\t',
      53 => '0\tR\t0.00\t',
      56 => romanian ? '0\t$documentNumber\t$z\t$fiscalNumber\t' : '0\t42\t',
      _ => '0\t',
    };
    final data = [
      request[5],
      ...request.sublist(6, 10),
      ...ascii.encode(value),
      4,
      ...List.filled(8, 0x80),
      5,
    ];
    final body = [
      ...DatecsGatewayProtocol.nibbles(data.length + 4 + 32),
      ...data,
    ];
    final response = [
      1,
      ...body,
      ...DatecsGatewayProtocol.nibbles(body.fold<int>(0, (a, b) => a + b)),
      3,
    ];
    if (corruptJournal && command == 125) response[response.length - 2] ^= 1;
    return response;
  }

  @override
  Future<void> close() async {}
}

void main() {
  FiscalConnection connection() => FiscalConnection(
    id: 'datecs',
    model: FiscalModel.datecsDp25,
    endpoint: LanEndpoint(host: '192.168.1.144', port: 3999),
    operatorNumber: 1,
    operatorPassword: '0001',
    cashPaymentCode: '0',
    cardPaymentCode: '1',
  );
  test(
    'Datecs MX validates subtotal/payment and returns the closed receipt',
    () async {
      final peer = FiscalPeer();
      final result = await DatecsMxFiscalAdapter(
        connection(),
        sessions: (_) async => peer,
      ).printReceipt(fixtures.receipt());
      expect(result.outcome, CommandOutcome.succeeded);
      expect(result.reference, '42');
      expect(peer.commands, [76, 123, 48, 49, 51, 54, 54, 54, 54, 53, 56]);
      expect(peer.payloads[49], 'Cafea\t1\t20.00\t1\t0\t\t0\t');
      expect(peer.payloads[53], '0\t20.00\t');
    },
  );
  test(
    'wrong subtotal never dispatches payment or closes a wrong total',
    () async {
      final peer = FiscalPeer()..subtotal = '20.01';
      final result = await DatecsMxFiscalAdapter(
        connection(),
        sessions: (_) async => peer,
      ).printReceipt(fixtures.receipt());
      expect(result.outcome, CommandOutcome.unknown);
      expect(peer.commands, [76, 123, 48, 49, 51]);
    },
  );
  test('lost close response remains unknown without a retry', () async {
    final peer = FiscalPeer()..loseOn = 56;
    final result = await DatecsMxFiscalAdapter(
      connection(),
      sessions: (_) async => peer,
    ).printReceipt(fixtures.receipt());
    expect(result.outcome, CommandOutcome.unknown);
    expect(peer.commands.where((c) => c == 56), hasLength(1));
  });
  test('lost close recovers exact EJ document using only reads', () async {
    final peer = FiscalPeer()..loseOn = 56;
    Map<String, dynamic>? evidence;
    final receipt = fixtures.receipt();
    final first = await DatecsMxFiscalAdapter(
      connection(),
      sessions: (_) async => peer,
      checkpoint: (value) async {
        evidence = Map.from(value);
      },
    ).printReceipt(receipt);
    expect(first.outcome, CommandOutcome.unknown);
    expect(evidence?['closeAttempted'], true);
    peer.commands.clear();
    final result = await DatecsReceiptRecovery.read(
      connection().endpoint,
      receipt.commandId,
      evidence,
      sessions: (_) async => peer,
    );
    expect(result.outcome, CommandOutcome.succeeded);
    expect(result.fiscalIdentity['zNumber'], '5');
    expect(peer.commands.every((c) => [123, 76, 125].contains(c)), true);
    expect(peer.payloads[125], '1\t');
  });
  for (final fault in [
    'serial',
    'number',
    'cancelled',
    'marker',
    'checksum',
    'noCheckpoint',
  ]) {
    test('Datecs refuses ambiguous recovery: $fault', () async {
      final peer = FiscalPeer()..loseOn = 56;
      Map<String, dynamic>? evidence;
      final receipt = fixtures.receipt();
      await DatecsMxFiscalAdapter(
        connection(),
        sessions: (_) async => peer,
        checkpoint: (value) async {
          evidence = Map.from(value);
        },
      ).printReceipt(receipt);
      switch (fault) {
        case 'serial':
          peer.serial = 'ANOTHER001';
        case 'number':
          peer.documentNumber = '43';
        case 'cancelled':
          peer.documentType = '8';
        case 'marker':
          peer.markers[0] = 'CHM1:wrong';
        case 'checksum':
          peer.loseOn = 125;
        case 'noCheckpoint':
          evidence = null;
      }
      peer.commands.clear();
      expect(
        (await DatecsReceiptRecovery.read(
          connection().endpoint,
          receipt.commandId,
          evidence,
          sessions: (_) async => peer,
        )).outcome,
        CommandOutcome.unknown,
      );
      expect(peer.commands.every((c) => [123, 76, 125].contains(c)), true);
    });
  }

  FiscalPeer rouPeer() => FiscalPeer()
    ..romanian = true
    ..documentNumber = '98765432';
  test('ROU MX returns fiscal number within Z, not the global slip', () async {
    final peer = rouPeer();
    Map<String, dynamic>? checkpoint;
    final result = await DatecsMxFiscalAdapter(
      connection(),
      sessions: (_) async => peer,
      checkpoint: (value) async {
        checkpoint = Map.from(value);
      },
    ).printReceipt(fixtures.receipt());
    expect(result.outcome, CommandOutcome.succeeded);
    expect(result.reference, '1500');
    expect(result.fiscalIdentity, {
      'serialNumber': 'DTTEST0001',
      'fiscalSerialNumber': 'FM001',
      'documentNumber': '98765432',
      'receiptNumber': '1500',
      'zNumber': '123',
    });
    expect(checkpoint?['profile'], 'rouMx');
    expect(checkpoint?['zNumber'], '123');
    expect(checkpoint?['closed'], true);
      expect(peer.requests.where((r)=>r.$1==54).map((r)=>r.$2),
        DatecsReceiptRecovery.markers(fixtures.receipt().commandId).map((m)=>'$m\t\t\t\t\t\t\t'));
  });
  test(
    'ROU MX lost ACK survives restart and resolves exact Z/receipt without writes',
    () async {
      final peer = rouPeer()..loseOn = 56;
      Map<String, dynamic>? evidence;
      final receipt = fixtures.receipt();
      expect(
        (await DatecsMxFiscalAdapter(
          connection(),
          sessions: (_) async => peer,
          checkpoint: (v) async {
            evidence = jsonDecode(jsonEncode(v));
          },
        ).printReceipt(receipt)).outcome,
        CommandOutcome.unknown,
      );
      final restarted = rouPeer()..markers.addAll(peer.markers);
      final result = await DatecsReceiptRecovery.read(
        connection().endpoint,
        receipt.commandId,
        evidence,
        sessions: (_) async => restarted,
      );
      expect(result.outcome, CommandOutcome.succeeded);
      expect(result.reference, '1500');
      expect(result.fiscalIdentity['zNumber'], '123');
      expect(restarted.requests.take(4).toList(), [
        (123, '1\t'),
        (76, ''),
        (125, '0\t98765432\t0\t'),
        (125, '0\t1231500\t1\t'),
      ]);
      expect(restarted.commands.every((c) => [123, 76, 125].contains(c)), true);
      expect(restarted.requests.skip(4).every((r) => r == (125, '1\t')), true);
    },
  );
  test(
    'ROU MX durable reconciliation is concurrent-safe and survives another restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'datecs-rou-recovery-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/journal');
      final evidenceFile = File('${directory.path}/checkpoint');
      final peer = rouPeer()..loseOn = 56;
      final receipt = fixtures.receipt();
      final payload = receipt.toJson();
      final adapter = DatecsMxFiscalAdapter(
        connection(),
        sessions: (_) async => peer,
        checkpoint: (v) =>
            evidenceFile.writeAsString(jsonEncode(v), flush: true),
      );
      final journal = CommandJournal(file);
      final initial = await journal.execute(
        id: receipt.commandId,
        deviceId: 'datecs',
        operation: 'fiscalReceipt',
        payload: payload,
        dispatch: () => adapter.printReceipt(receipt),
      );
      expect(initial.outcome, CommandOutcome.unknown);
      final recoveredPeer = rouPeer()..markers.addAll(peer.markers);
      var reads = 0;
      Future<HardwareResult> recover() => CommandJournal(file).execute(
        id: receipt.commandId,
        deviceId: 'datecs',
        operation: 'fiscalReceipt',
        payload: payload,
        recoveryOnly: true,
        reconcile: () async {
          reads++;
          return DatecsReceiptRecovery.read(
            connection().endpoint,
            receipt.commandId,
            jsonDecode(await evidenceFile.readAsString()),
            sessions: (_) async => recoveredPeer,
          );
        },
        dispatch: () async => throw StateError('Recovery must not print'),
      );
      final results = await Future.wait([recover(), recover()]);
      // The journal's existing file guard rejects a simultaneous caller as busy;
      // LocalBridge queues callers above it. Busy must not overwrite the receipt.
      expect(results.map((r) => r.outcome), [
        CommandOutcome.succeeded,
        CommandOutcome.rejected,
      ]);
      expect(results[1].message, 'Companion execută deja o comandă');
      expect(reads, 1);
      expect((await recover()).fiscalIdentity['receiptNumber'], '1500');
      expect(reads, 1);
      expect(peer.commands.where((c) => c == 48), hasLength(1));
      expect(peer.commands.where((c) => c == 53), hasLength(1));
      expect(peer.commands.where((c) => c == 56), hasLength(1));
      await expectLater(
        CommandJournal(file).execute(
          id: receipt.commandId,
          deviceId: 'datecs',
          operation: 'fiscalReceipt',
          payload: {...payload, 'totalMinor': 2001},
          recoveryOnly: true,
          dispatch: () async => throw StateError('Never dispatch'),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'ROU MX can recover pre-upgrade asciiMx evidence using full Romanian EJ schema',
    () async {
      final receipt = fixtures.receipt();
      final peer = rouPeer()
        ..markers.addAll(DatecsReceiptRecovery.markers(receipt.commandId));
      final evidence = {
        'profile': 'asciiMx',
        'commandId': receipt.commandId,
        'serialNumber': peer.serial,
        'receiptNumber': peer.documentNumber,
        'closeAttempted': true,
      };
      final result = await DatecsReceiptRecovery.read(
        connection().endpoint,
        receipt.commandId,
        evidence,
        sessions: (_) async => peer,
      );
      expect(result.outcome, CommandOutcome.succeeded);
      expect(result.fiscalIdentity['receiptNumber'], '1500');
    },
  );
  for (final fault in [
    'serial',
    'fiscalSerial',
    'Z',
    'typedDocument',
    'receipt',
    'nonFiscal',
    'marker',
    'checksum',
    'openDocument',
    'downgrade',
    'missingCheckpoint',
  ]) {
    test('ROU MX refuses $fault, never reissues', () async {
      final receipt = fixtures.receipt();
      final peer = rouPeer()
        ..markers.addAll(DatecsReceiptRecovery.markers(receipt.commandId));
      Map<String, dynamic>? evidence = {
        'profile': 'rouMx',
        'commandId': receipt.commandId,
        'serialNumber': peer.serial,
        'fiscalSerialNumber': peer.fiscalSerial,
        'receiptNumber': peer.documentNumber,
        'zNumber': '123',
        'closeAttempted': true,
      };
      switch (fault) {
        case 'serial':
          peer.serial = 'OTHER001';
        case 'fiscalSerial':
          peer.fiscalSerial = 'FM002';
        case 'Z':
          peer.journalZ = '124';
        case 'typedDocument':
          peer.typedDocument = '98765433';
        case 'receipt':
          peer.fiscalNumber = '0';
        case 'nonFiscal':
          peer.documentType = '4';
        case 'marker':
          peer.markers[3] = 'CHM4:incorrect';
        case 'checksum':
          peer.corruptJournal = true;
        case 'openDocument':
          peer.openDocument = true;
        case 'downgrade':
          peer.romanian = false;
        case 'missingCheckpoint':
          evidence = null;
      }
      final result = await DatecsReceiptRecovery.read(
        connection().endpoint,
        receipt.commandId,
        evidence,
        sessions: (_) async => peer,
      );
      expect(result.outcome, CommandOutcome.unknown);
      expect(peer.commands.every((c) => [123, 76, 125].contains(c)), true);
    });
  }
}
