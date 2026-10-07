import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/fiscal_device.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/datecs_gateway_protocol.dart';
import 'package:chimera_companion/hardware/tcp_transport.dart';
import 'adapters_test.dart' as fixtures;

class FiscalPeer implements ByteSession {
  final commands = <int>[];
  final payloads = <int, String>{};
  String subtotal = '20.00';
  int? loseOn;
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
    if (command == loseOn) throw StateError('Reply lost');
    final value = switch (command) {
      76 => '0\t0\t',
      51 => '0\t1\t$subtotal\t',
      53 => '0\tR\t0.00\t',
      56 => '0\t42\t',
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
      expect(peer.commands, [76, 48, 49, 51, 53, 56]);
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
      expect(peer.commands, [76, 48, 49, 51]);
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
}
