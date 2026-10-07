import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/tcp_transport.dart';
import 'package:chimera_companion/hardware/tremol_adapter.dart';
import 'package:chimera_companion/hardware/tremol_protocol.dart';
import 'package:chimera_companion/hardware/datecs_gateway_adapter.dart';
import 'package:chimera_companion/hardware/datecs_gateway_protocol.dart';

class TremolPeer implements ByteSession {
  final List<int> commands = [];
  int? loseOn;
  int? reject03On;
  int registerFlags = 0;
  String subtotal = '20.00';
  String operatorName = 'Test operator';
  bool closed = false;
  int busyReplies = 0;
  int polls = 0;
  bool needsPassword = false;
  int passwordReplies = 0;
  final List<List<int>> requests = [];
  @override
  Future<List<int>> exchange(
    List<int> request,
    int? Function(List<int>) frameLength,
  ) async {
    requests.add(request);
    if (request.length > 1 && request.first != 2) {
      expect(request, [...ascii.encode('test-lan'), 10, 9]);
      needsPassword = false;
      passwordReplies++;
      return [0x40];
    }
    if (request.length == 1 && request.single == 9) {
      polls++;
      if (needsPassword) return [0x50];
      if (busyReplies > 0) {
        busyReplies--;
        return [0x41];
      }
      return [0x40];
    }
    final command = request[3];
    final sequence = request[2];
    commands.add(command);
    if (command == reject03On) {
      final body = [sequence, 0x30, 0x33];
      final sum = body.fold<int>(0, (a, b) => a ^ b);
      return [6, ...body, 0x30 + (sum >> 4), 0x30 + (sum & 15), 10];
    }
    if (command == loseOn) throw StateError('Socket disconnected after write');
    if (command == 0x4a) {
      operatorName = latin1
          .decode(request.sublist(4, request.length - 3))
          .split(';')[1]
          .trim();
    }
    final data = switch (command) {
      0x20 => [0, registerFlags, 0, 0x30, 0, 0, 0],
      0x33 => ascii.encode(subtotal),
      0x71 => ascii.encode('0001;0000001'),
      0x6a => ascii.encode('1;${operatorName.padRight(20)};1234;'),
      0x62 => ascii.encode('21.00%;11.00%;11.00%;00.00%;00.00%;00.00%;'),
      _ => null,
    };
    if (data != null) return TremolProtocol.encode(sequence, command, data);
    final body = [sequence, 0x30, 0x30];
    final sum = body.fold<int>(0, (a, b) => a ^ b);
    return [6, ...body, 0x30 + (sum >> 4), 0x30 + (sum & 15), 10];
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

FiscalConnection connection({String tcpPassword = ''}) => FiscalConnection(
  id: 'ecr',
  model: FiscalModel.tremolM20,
  endpoint: LanEndpoint(host: '192.168.1.20', port: 9100),
  operatorNumber: 1,
  operatorPassword: '1234',
  cashPaymentCode: '0',
  cardPaymentCode: '1',
  tcpPassword: tcpPassword,
);
FiscalReceipt receipt({String name = 'Cafea',String? cui}) => FiscalReceipt(
  commandId: 'cmd',
  currency: 'RON',
  paymentMethod: FiscalPaymentMethod.cash,
  totalMinor: 2000,
  cui:cui,
  lines: [
    FiscalLine(
      name: name,
      quantityDecimal: '1',
      grossTotalMinor: 2000,
      unitPriceMinor: 2000,
      vatGroup: 'A',
    ),
  ],
);

class DatecsPeer implements ByteSession {
  final List<List<int>> requests = [];
  @override
  Future<List<int>> exchange(
    List<int> request,
    int? Function(List<int>) frameLength,
  ) async {
    requests.add(request);
    final data = [
      request[5],
      ...request.sublist(6, 10),
      ...ascii.encode('0\t'),
      4,
      ...List.filled(8, 0x80),
      5,
    ];
    final body = [
      ...DatecsGatewayProtocol.nibbles(data.length + 4 + 32),
      ...data,
    ];
    return [
      1,
      ...body,
      ...DatecsGatewayProtocol.nibbles(body.fold<int>(0, (a, b) => a + b)),
      3,
    ];
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('RO cash deposit and withdrawal use signed amounts and the operator password',() async {
    for(final withdrawal in [false,true]) {
      final peer=TremolPeer();
      final result=await TremolAdapter(connection(),sessions:(_)async=>peer).cashMovement(CashMovementRequest(commandId:'cash-1',amountMinor:500,withdrawal:withdrawal,reason:'Fond initial'));
      expect(result.outcome,CommandOutcome.succeeded);
      final request=peer.requests.firstWhere((r)=>r.length>3&&r[3]==0x3b);
      expect(ascii.decode(request.sublist(4,request.length-3)),'1;1234;0;${withdrawal?'-':''}5.00@Fond initial');
      expect(peer.commands.where((c)=>c==0x3b),hasLength(1));
    }
  });
  test('cash timeout is unknown and never retries the command',() async {
    final peer=TremolPeer()..loseOn=0x3b;
    final result=await TremolAdapter(connection(),sessions:(_)async=>peer).cashMovement(CashMovementRequest(commandId:'cash-1',amountMinor:500,withdrawal:false,reason:'Fond'));
    expect(result.outcome,CommandOutcome.unknown);expect(peer.commands.where((c)=>c==0x3b),hasLength(1));
  });
  test('buyer tax ID uses the RO special fiscal document field, not free text',() async {
    final peer=TremolPeer();
    await TremolAdapter(connection(),sessions:(_)async=>peer).printReceipt(receipt(cui:'RO14399840'));
    final open=peer.requests.firstWhere((r)=>r.length>3&&r[3]==0x30);
    final fields=ascii.decode(open.sublist(4,open.length-3)).split(';');
    expect(fields[4],'1');expect(fields[5],'RO14399840'.padRight(15));
    expect(peer.commands, isNot(contains(0x37)));
  });
  test('raw diagnostic sends one frame and returns actual response bytes', () async {
    final peer = TremolPeer();
    final result = await TremolAdapter(connection(), sessions: (_) async => peer).rawCommand(0x20, []);
    expect(result.outcome, CommandOutcome.succeeded);
    expect(result.message, startsWith('RX '));
    expect(peer.commands, [0x20]);
  });
  test('raw command timeout never resends', () async {
    final peer = TremolPeer()..loseOn = 0x7d;
    final result = await TremolAdapter(connection(), sessions: (_) async => peer).rawCommand(0x7d, ascii.encode('Z;0'));
    expect(result.outcome, CommandOutcome.unknown);
    expect(peer.commands, [0x7d]);
  });
  test(
    'RO operator reset targets all operators, never daily Z',
    () async {
      final peer = TremolPeer();
      final result = await TremolAdapter(
        connection(),
        sessions: (_) async => peer,
      ).resetConfiguredOperatorReport();
      expect(result.outcome, CommandOutcome.succeeded);
      final request = peer.requests.singleWhere(
        (r) => r.length > 3 && r[3] == 0x7d,
      );
      expect(ascii.decode(request.sublist(4, request.length - 3)), 'Z;0');
      expect(peer.commands, isNot(contains(0x7c)));
    },
  );

  test(
    'lost operator reset response remains unknown and is not resent',
    () async {
      final peer = TremolPeer()..loseOn = 0x7d;
      final result = await TremolAdapter(
        connection(),
        sessions: (_) async => peer,
      ).resetConfiguredOperatorReport();
      expect(result.outcome, CommandOutcome.unknown);
      expect(peer.commands.where((c) => c == 0x7d).length, 1);
      expect(peer.commands, isNot(contains(0x7c)));
    },
  );
  test(
    'Tremol reads real VAT groups without assuming rate-to-letter mappings',
    () async {
      final peer = TremolPeer();
      expect(
        await TremolAdapter(
          connection(),
          sessions: (_) async => peer,
        ).readVatRates(),
        {'A': 21.0, 'B': 11.0, 'C': 11.0, 'D': 0.0, 'E': 0.0},
      );
      expect(peer.commands, [0x62]);
    },
  );
  test('Tremol setup reads operator without fiscal writes', () async {
    final peer = TremolPeer();
    final operator = await TremolAdapter(
      connection(),
      sessions: (_) async => peer,
    ).readOperatorConfiguration();
    expect(operator, {'name': 'Test operator', 'password': '1234'});
    expect(peer.commands, [0x6a]);
    expect(peer.closed, isTrue);
  });
  test('status exposes fiscal register flags without printing', () async {
    final peer = TremolPeer()..registerFlags = 0x28;
    final status = await TremolAdapter(connection(), sessions: (_) async => peer).readStatus();
    expect(status.details['dailyReportNonZero'], true);
    expect(status.details['operatorReportNonZero'], true);
    expect(status.details['articleReportNonZero'], false);
    expect(peer.commands, [0x20]);
  });
  test('03 identifies exact rejected programming command, not an operator report request', () async {
    final peer = TremolPeer()..reject03On = 0x4a;
    final result = await TremolAdapter(connection(), sessions: (_) async => peer).renameConfiguredOperator('admin');
    expect(result.reference, 'daily_report_not_zero');
    expect(result.message, contains('4Ah'));
    expect(peer.commands, [0x20, 0x6a, 0x4a]);
  });
  test(
    'operator login renames configured slot and verifies without receipt or Z',
    () async {
      final peer = TremolPeer();
      final adapter = TremolAdapter(connection(), sessions: (_) async => peer);
      final result = await adapter.renameConfiguredOperator('admin');
      expect(result.outcome, CommandOutcome.succeeded);
      expect(peer.operatorName, 'admin');
      expect(peer.commands, [0x20, 0x6a, 0x4a, 0x6a]);
    },
  );
  test(
    'operator login returns unknown after lost write response, never emits Z',
    () async {
      final peer = TremolPeer()..loseOn = 0x4a;
      final result = await TremolAdapter(
        connection(),
        sessions: (_) async => peer,
      ).renameConfiguredOperator('admin');
      expect(result.outcome, CommandOutcome.unknown);
      expect(peer.commands, [0x20, 0x6a, 0x4a]);
    },
  );
  test('Z dispatches the zeroing operation exactly once', () async {
    final peer = TremolPeer();
    final result = await TremolAdapter(
      connection(),
      sessions: (_) async => peer,
    ).printReport(closeDay: true);
    expect(result.outcome, CommandOutcome.succeeded);
    final requests = peer.requests
        .where((r) => r.length > 3 && r[3] == 0x7c)
        .toList();
    expect(requests, hasLength(1));
    expect(
      requests.single.sublist(4, requests.single.length - 3),
      ascii.encode('Z'),
    );
  });
  test('Tremol non-fiscal uses only non-fiscal document commands', () async {
    final peer = TremolPeer();
    final result = await TremolAdapter(
      connection(),
      sessions: (_) async => peer,
    ).printNonFiscal(['CHIMERA TEST']);
    expect(result.outcome, CommandOutcome.succeeded);
    expect(peer.commands, [0x20, 0x2e, 0x37, 0x2f]);
  });
  test(
    'X report is always non-zeroing and waits for printer readiness',
    () async {
      final peer = TremolPeer();
      final result = await TremolAdapter(
        connection(),
        sessions: (_) async => peer,
      ).printXReport();
      expect(result.outcome, CommandOutcome.succeeded);
      final request = peer.requests.singleWhere(
        (r) => r.length > 3 && r[3] == 0x7c,
      );
      expect(request.sublist(4, request.length - 3), ascii.encode('X'));
      expect(peer.requests.last, [9]);
      expect(peer.closed, true);
    },
  );
  test('Tremol authenticates LAN separately from fiscal operator', () async {
    final peer = TremolPeer()..needsPassword = true;
    final result = await TremolAdapter(
      connection(tcpPassword: 'test-lan'),
      sessions: (_) async => peer,
    ).printReceipt(receipt());
    expect(result.outcome, CommandOutcome.succeeded);
    expect(peer.passwordReplies, 1);
  });
  test('Tremol missing LAN password never dispatches a receipt', () async {
    final peer = TremolPeer()..needsPassword = true;
    final result = await TremolAdapter(
      connection(),
      sessions: (_) async => peer,
    ).printReceipt(receipt());
    expect(result.outcome, CommandOutcome.rejected);
    expect(peer.commands, isEmpty);
  });
  test('Tremol pads the sale name to the vendor 36-byte field', () {
    final data = TremolAdapter(connection()).prepareLines(receipt()).single;
    expect(ascii.decode(data), '${'Cafea'.padRight(36)};A;20.00*1');
  });
  test('Tremol polls busy without resending fiscal commands', () async {
    final peer = TremolPeer()..busyReplies = 2;
    final result = await TremolAdapter(
      connection(),
      sessions: (_) async => peer,
    ).printReceipt(receipt());
    expect(result.outcome, CommandOutcome.succeeded);
    expect(peer.polls, 9);
    expect(peer.commands.where((c) => c == 0x31).length, 1);
  });
  test(
    'Tremol completes real command sequence, including subtotal validation',
    () async {
      final peer = TremolPeer();
      final result = await TremolAdapter(
        connection(),
        sessions: (_) async => peer,
      ).printReceipt(receipt());
      expect(result.outcome, CommandOutcome.succeeded);
      expect(peer.commands, [0x20, 0x30, 0x31, 0x33, 0x35, 0x38, 0x71]);
      expect(peer.closed, true);
    },
  );
  test('changed ECR subtotal prevents payment and receipt closure', () async {
    final peer = TremolPeer()..subtotal = '20.01';
    final result = await TremolAdapter(
      connection(),
      sessions: (_) async => peer,
    ).printReceipt(receipt());
    expect(result.outcome, CommandOutcome.unknown);
    expect(peer.commands, [0x20, 0x30, 0x31, 0x33]);
  });
  test('lost closure response is unknown and never retransmitted', () async {
    final peer = TremolPeer()..loseOn = 0x38;
    final result = await TremolAdapter(
      connection(),
      sessions: (_) async => peer,
    ).printReceipt(receipt());
    expect(result.outcome, CommandOutcome.unknown);
    expect(peer.commands.where((cmd) => cmd == 0x38).length, 1);
  });
  test('unsupported text is rejected before socket connection', () async {
    var connections = 0;
    final adapter = TremolAdapter(
      connection(),
      sessions: (_) async {
        connections++;
        return TremolPeer();
      },
    );
    await expectLater(
      adapter.printReceipt(receipt(name: 'Cafea;injection')),
      throwsArgumentError,
    );
    expect(connections, 0);
  });
  test(
    'Datecs retains gateway non-fiscal opening/text/closing bytes',
    () async {
      final peer = DatecsPeer();
      final result = await DatecsGatewayAdapter(
        connection().endpoint,
        sessions: (_) async => peer,
      ).printNonFiscal(['HELLO WORLD']);
      expect(result.outcome, CommandOutcome.succeeded);
      expect(peer.requests, [
        DatecsGatewayProtocol.encode(38, '', sequence: peer.requests[0][5]),
        DatecsGatewayProtocol.encode(
          42,
          'HELLO WORLD\t\t\t\t\t\t',
          sequence: peer.requests[1][5],
        ),
        DatecsGatewayProtocol.encode(39, '', sequence: peer.requests[2][5]),
      ]);
    },
  );
}
