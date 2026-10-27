import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/printing/production_print.dart';
import 'package:chimera_companion/hardware/command_executor.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/local_bridge.dart';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'package:chimera_companion/erp_commands.dart';
import 'signed_http_authorization_test.dart'
    show SigningFixture, NetworkTestBinding;
import 'tls_fixture.dart';

Map<String, dynamic> config({String protocol = 'escpos'}) => {
  'name': 'Workshop',
  'protocol': protocol,
  'host': '192.168.1.30',
  'port': 9100,
  'widthDots': 576,
  'heightDots': 1600,
};
Map<String, dynamic> job({
  String id = 'print-1',
  String operation = 'productionWorkTicket',
}) => {
  'version': 1,
  'commandId': id,
  'operation': operation,
  'printerId': 'printer:192.168.1.30:9100',
  'operationId': 'operation-1',
  'product': 'Croissant cu ciocolată',
  'lot': 'LOT-001',
  'quantity': '12.5',
  'unit': 'kg',
  'producedAt': '2026-10-17T08:00:00Z',
  'expiresAt': '2026-10-19T08:00:00Z',
  'provisional': true,
  'reprintOf': null,
  'reprintReason': null,
};

void main() {
  NetworkTestBinding();
  late Directory directory;
  setUp(
    () async => directory = await Directory.systemTemp.createTemp(
      'production-print-test-',
    ),
  );
  tearDown(() async => directory.delete(recursive: true));

  test(
    'bounded templates contain full traceability and provisional mark for both protocols',
    () {
      for (final protocol in ['escpos', 'zpl']) {
        final bytes = ProductionPrintJob(
          job(
            operation: protocol == 'escpos'
                ? 'productionWorkTicket'
                : 'productionLabel',
          ),
        ).render(PrinterConfig.fromJson(config(protocol: protocol)));
        final text = ascii.decode(bytes);
        for (final expected in [
          'Croissant cu ciocolata',
          'LOT-001',
          '12.5 kg',
          '2026-10-17T08:00:00Z',
          '2026-10-19T08:00:00Z',
          'PROVISIONAL OFFLINE',
          'operation-1',
          'print-1',
        ]) {
          // Templates may wrap long strings but never drop their bytes.
          expect(text.replaceAll('\n', ''), contains(expected));
        }
        if (protocol == 'zpl') {
          expect(text, startsWith('^XA'));
          expect(text, endsWith('^XZ'));
        }
      }
    },
  );
  test(
    'rejects command injection, arbitrary fields, unbounded content and remote endpoints',
    () {
      for (final value in [
        'bad\x1b@',
        'bad\nTEXT',
        '^XZ',
        '~JA',
        r'\5E',
        'x' * 81,
      ]) {
        expect(
          () => ProductionPrintJob({...job(), 'product': value}),
          throwsFormatException,
        );
      }
      expect(
        () => ProductionPrintJob({...job(), 'raw': '^XA'}),
        throwsFormatException,
      );
      expect(
        () => ProductionPrintJob({...job(), 'quantity': '0'}),
        throwsFormatException,
      );
      for (final host in [
        '8.8.8.8',
        'localhost',
        '127.0.0.1',
        '169.254.169.254',
        '192.168.1.255',
      ]) {
        expect(
          () => PrinterConfig.fromJson({...config(), 'host': host}),
          throwsFormatException,
        );
      }
      expect(
        () => ProductionPrintJob(
          job(),
        ).render(PrinterConfig.fromJson(config(protocol: 'zpl'))),
        throwsFormatException,
      );
    },
  );
  test(
    'leased assigned-work template names planned output and real reserved input without claiming production',
    () {
      final payload = {...job(), 'version': 2, 'factKind': 'assigned_work'};
      final rendered = ascii.decode(
        ProductionPrintJob(payload).render(PrinterConfig.fromJson(config())),
      );
      expect(rendered, contains('ASSIGNED WORK - PLANNED OUTPUT'));
      expect(rendered, contains('Reserved input lot: LOT-001'));
      expect(rendered, contains('Planned qty: 12.5 kg'));
      expect(rendered, contains('Started: 2026-10-17T08:00:00Z'));
      expect(rendered, contains('PROVISIONAL OFFLINE'));
      expect(rendered, isNot(contains('Produced:')));
      expect(
        () => ProductionPrintJob({...payload, 'operation': 'productionLabel'}),
        throwsFormatException,
      );
      expect(
        () => ProductionPrintJob({...payload, 'provisional': false}),
        throwsFormatException,
      );
    },
  );
  test(
    'durable unknown send survives duplicate, restart, partial failure and explicit reprint',
    () async {
      var sends = 0;
      var fail = false;
      final journal = CommandJournal(File('${directory.path}/journal'));
      ProductionPrinter printer() => ProductionPrinter(
        executor: HardwareCommandExecutor(),
        journal: journal,
        send: (_, _) async {
          sends++;
          if (fail) throw const SocketException('partial send');
        },
      );
      final cfg = PrinterConfig.fromJson(config());
      Future<Map<String, Object?>> execute(
        ProductionPrinter p,
        Map<String, dynamic> payload,
      ) => p.execute(cfg, ProductionPrintJob(payload), authorize: () async {});
      final first = await execute(printer(), job());
      expect(first['outcome'], 'unknown');
      expect(first['delivery'], 'sent_unconfirmed');
      expect((await execute(printer(), job()))['delivery'], 'sent_unconfirmed');
      expect(sends, 1);
      await expectLater(
        execute(printer(), {...job(), 'quantity': '13'}),
        throwsStateError,
      );
      fail = true;
      expect(
        (await execute(printer(), job(id: 'partial')))['delivery'],
        'unknown',
      );
      await execute(printer(), job(id: 'partial'));
      expect(sends, 2);
      fail = false;
      await execute(printer(), {
        ...job(id: 'reprint'),
        'reprintOf': 'print-1',
        'reprintReason': 'Label damaged',
      });
      expect(sends, 3);
      final entries = const LineSplitter()
          .convert(await journal.file.readAsString())
          .map(jsonDecode)
          .toList();
      expect(entries.last['reprintOf'], 'print-1');
      expect(entries.last['reprintReason'], 'Label damaged');
      await expectLater(
        execute(printer(), {
          ...job(id: 'bad-reprint'),
          'reprintOf': 'absent',
          'reprintReason': 'Retry',
        }),
        throwsFormatException,
      );
      expect(sends, 3);
    },
  );
  test(
    'queued authorization is checked before journal claim or send; recovery never sends',
    () async {
      var sends = 0;
      final journal = CommandJournal(File('${directory.path}/journal'));
      final printer = ProductionPrinter(
        executor: HardwareCommandExecutor(),
        journal: journal,
        send: (_, _) async {
          sends++;
        },
      );
      await expectLater(
        printer.execute(
          PrinterConfig.fromJson(config()),
          ProductionPrintJob(job()),
          authorize: () async {
            throw const FormatException('expired');
          },
        ),
        throwsFormatException,
      );
      expect(await journal.recent(), isEmpty);
      expect(sends, 0);
      final recovery = await printer.execute(
        PrinterConfig.fromJson(config()),
        ProductionPrintJob(job()),
        authorize: () async {},
        recover: true,
      );
      expect(recovery['journalFound'], false);
      expect(sends, 0);
    },
  );
  test('concurrent identical commands share one durable send', () async {
    var sends = 0;
    final pending = Completer<void>();
    final printer = ProductionPrinter(
      executor: HardwareCommandExecutor(),
      journal: CommandJournal(File('${directory.path}/journal')),
      send: (_, _) async {
        sends++;
        await pending.future;
      },
    );
    final first = printer.execute(
      PrinterConfig.fromJson(config()),
      ProductionPrintJob(job()),
      authorize: () async {},
    );
    final second = printer.execute(
      PrinterConfig.fromJson(config()),
      ProductionPrintJob(job()),
      authorize: () async {},
    );
    await expectLater(
      printer.execute(
        PrinterConfig.fromJson(config()),
        ProductionPrintJob(job()),
        authorize: () async {},
        audit: {'authorizedActor': 'another-operator'},
      ),
      throwsStateError,
    );
    pending.complete();
    await Future.wait([first, second]);
    expect(sends, 1);
  });

  test(
    'actual signed HTTPS dispatch works without ECR and rejects tampering and fiscal grants',
    () async {
      final tls = await TlsFixture.create();
      final authority = SigningFixture(61), identity = SigningFixture(62);
      final now = DateTime.now().toUtc();
      final seconds = now.millisecondsSinceEpoch ~/ 1000;
      final session = OfflineSession(
        file: File('${directory.path}/trust'),
        org: 'org',
        location: 'location',
        companion: 'companion',
        identity: identity,
        now: () => now,
      );
      await session.restore();
      await session.updateTrust({
        'signing_keys': [
          {...authority.jwk, 'kid': 'fixture-authority'},
        ],
        'peers': [],
        'equipment': [
          {
            'kind': 'printer',
            'companion_id': 'companion',
            'host': '192.168.1.30',
            'port': 9100,
          },
        ],
      });
      FlutterSecureStorage.setMockInitialValues({
        'production_printer_v1': jsonEncode(config()),
      });
      var sends = 0;
      final busyDuringSend = <bool>[];
      late LocalBridge runtime;
      LocalBridge bridge() => LocalBridge(
        journal: CommandJournal(File('${directory.path}/journal')),
        security: session,
        printerSend: (_, _) async {
          busyDuringSend.add(runtime.busy);
          sends++;
        },
      );
      runtime = bridge();
      final server = CompanionServer(
        verify: (_) async => {},
        run: (_, _, _) async => throw StateError('No POS'),
        runProductionPrint: (ticket, payload, origin) =>
            runtime.runProductionPrint(ticket, payload, origin),
      );
      final client = HttpClient(context: tls.clientContext);
      String ticket(
        Map<String, dynamic> payload, [
        Map<String, dynamic> overrides = const {},
      ]) => authority.token({
        'iss': 'chimera-companion',
        'kind': 'production-print',
        'version': 1,
        'org': 'org',
        'location': 'location',
        'aud': 'companion',
        'companion': 'companion',
        'sub': 'operator',
        'pos': 'kds',
        'iat': seconds,
        'nbf': seconds,
        'exp': seconds + 300,
        'origin': 'https://kds.example',
        'operations': [payload['operation']],
        'commandId': payload['commandId'],
        'printerId': payload['printerId'],
        'payloadHash': hardwarePayloadHash(payload),
        'provisional': payload['provisional'],
        ...overrides,
      });
      Future<(int, Map<String, dynamic>)> send(
        String token,
        Map<String, dynamic> payload, {
        String origin = 'https://kds.example',
      }) async {
        final request = await client.postUrl(
          Uri.parse('https://127.0.0.1:${server.port}/v1/production-print'),
        );
        request.headers.set('Origin', origin);
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({'ticket': token, 'payload': payload}));
        final response = await request.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
        );
      }

      try {
        await server.start(
          securityContext: tls.serverContext,
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        for (final overrides in [
          {'kind': 'erp'},
          {'org': 'foreign'},
          {'location': 'foreign'},
          {
            'operations': ['fiscalReceipt'],
          },
          {'exp': seconds - 1},
          {'printerId': 'foreign'},
        ]) {
          expect((await send(ticket(job(), overrides), job())).$1, 403);
        }
        expect(
          (await send(ticket(job()), {...job(), 'quantity': '15'})).$1,
          403,
        );
        expect(
          (await send(ticket(job()), job(), origin: 'https://evil.example')).$1,
          403,
        );
        expect(sends, 0);
        final online = {...job(), 'provisional': false};
        expect(
          (await send(ticket(online, {'exp': seconds + 301}), online)).$1,
          403,
        );
        expect(
          (await send(ticket(job(), {'exp': seconds + 604801}), job())).$1,
          403,
        );
        final result = await send(ticket(job()), job());
        expect(result.$1, 200);
        expect(
          jsonDecode(result.$2['resultJson'])['delivery'],
          'sent_unconfirmed',
        );
        await runtime.close();
        runtime = bridge();
        expect((await send(ticket(job()), job())).$1, 200);
        expect(sends, 1);
        for (final operation in [
          'productionLabel',
          'productionPrintDiagnostic',
        ]) {
          await const FlutterSecureStorage().write(
            key: 'production_printer_v1',
            value: jsonEncode(
              config(
                protocol: operation == 'productionLabel' ? 'zpl' : 'escpos',
              ),
            ),
          );
          final payload = job(id: operation, operation: operation);
          expect((await send(ticket(payload), payload)).$1, 200);
        }
        expect(sends, 3);
        expect(busyDuringSend, everyElement(isTrue));
        expect(runtime.busy, isFalse);
        final journalText = await File(
          '${directory.path}/journal',
        ).readAsString();
        final lastEntry = jsonDecode(
          const LineSplitter().convert(journalText).last,
        );
        expect(lastEntry['authorizedActor'], 'operator');
        expect(lastEntry['authorizedDevice'], 'kds');
        await session.updateTrust({
          'signing_keys': [
            {...authority.jwk, 'kid': 'fixture-authority'},
          ],
          'peers': [],
          'equipment': [],
        });
        expect(
          (await send(ticket(job(id: 'unassigned')), job(id: 'unassigned'))).$1,
          403,
        );
        expect(sends, 3);
      } finally {
        client.close(force: true);
        await server.close();
        await runtime.close();
        await tls.directory.delete(recursive: true);
      }
    },
  );
}
