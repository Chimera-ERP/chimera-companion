import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/datecs_device_client.dart';
import 'package:chimera_companion/hardware/datecs_gateway_protocol.dart';
import 'package:chimera_companion/hardware/tcp_transport.dart';

class Peer implements ByteSession {
  final requests = <List<int>>[];
  bool loseX = false;
  String state = '0';
  @override
  Future<List<int>> exchange(
    List<int> request,
    int? Function(List<int>) length,
  ) async {
    requests.add(request);
    final command = request
        .sublist(6, 10)
        .fold<int>(0, (a, b) => (a << 4) + b - 0x30);
    if (command == 69 && loseX) throw TimeoutException('lost');
    final payload = command == 76 ? '0\t$state\t517\t0\t0.00\t0.00\t' : '0\t';
    final data = [
      request[5],
      ...request.sublist(6, 10),
      ...ascii.encode(payload),
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
  test('decodes unmodified vendor command 76 response', () {
    const hex =
        '0130303437323030343c30093009353137093009302e303009302e3030090480808080869a80800530383d3503';
    final bytes = [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    expect(
      DatecsGatewayProtocol.decode(bytes, sequence: 0x32, command: 76).take(6),
      ['0', '0', '517', '0', '0.00', '0.00'],
    );
  });
  final endpoint = LanEndpoint(host: '192.168.1.144', port: 3999);
  test('auto detects MX without calling legacy SDK; X uses X TAB', () async {
    final peer = Peer();
    final client = DatecsDeviceClient(
      endpoint,
      sessions: (_) async => peer,
      legacyProbe: () async => throw StateError('must not fall back'),
    );
    final result = await client.printXReport();
    expect(result.outcome, CommandOutcome.succeeded);
    expect(
      ascii.decode(
        peer.requests.last.sublist(10, peer.requests.last.length - 6),
      ),
      'X\t',
    );
    expect(peer.requests.map((r) => r[5]).toSet().length, peer.requests.length);
  });
  test('lost X is unknown and never retried in another protocol', () async {
    final peer = Peer()..loseX = true;
    final result = await DatecsDeviceClient(
      endpoint,
      sessions: (_) async => peer,
      legacyProbe: () async => throw StateError('no fallback'),
    ).printXReport();
    expect(result.outcome, CommandOutcome.unknown);
    expect(peer.requests.length, 3);
  });
  test('open receipt blocks X before dispatch', () async {
    final peer = Peer()..state = '1';
    final result = await DatecsDeviceClient(
      endpoint,
      sessions: (_) async => peer,
    ).printXReport();
    expect(result.outcome, CommandOutcome.rejected);
    expect(peer.requests.length, 1);
  });
}
