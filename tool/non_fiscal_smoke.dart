// Explicit hardware smoke test. Never sends fiscal receipt/payment commands.
import 'dart:io';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/tcp_transport.dart';
import 'package:chimera_companion/hardware/datecs_gateway_protocol.dart';
import 'package:chimera_companion/hardware/datecs_gateway_adapter.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/runtime.dart';
import 'package:chimera_companion/hardware/contracts.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) throw ArgumentError('Usage: host port [--print]');
  final endpoint = LanEndpoint(host: args[0], port: int.parse(args[1]));
  final session = await TcpByteSession.connect(endpoint);
  try {
    final sequence = DatecsGatewayProtocol.nextSequence(
      '${endpoint.host}:${endpoint.port}',
    );
    final bytes = await session.exchange(
      DatecsGatewayProtocol.encode(76, '', sequence: sequence),
      DatecsGatewayProtocol.frameLength,
    );
    final state = DatecsGatewayProtocol.decode(
      bytes,
      sequence: sequence,
      command: 76,
    );
    final bits = bytes.sublist(bytes.length - 14, bytes.length - 6);
    stdout.writeln('Datecs 76: $state; status bytes: $bits');
    if (state.length < 2 ||
        state[1] != '0' ||
        bits[0] & 0x70 != 0 ||
        bits[2] & 0x05 != 0) {
      throw StateError('ECR not ready; no printing dispatched');
    }
  } finally {
    await session.close();
  }
  if (!args.contains('--print')) return;
  final result =
      await HardwareRuntime(
        CommandJournal(
          File('${Directory.systemTemp.path}/chimera-nonfiscal-smoke.jsonl'),
        ),
      ).nonFiscal(
        '${endpoint.host}:${endpoint.port}',
        DatecsGatewayAdapter(endpoint),
        'nonfiscal-smoke-${DateTime.now().microsecondsSinceEpoch}',
        [
          'CHIMERA - TEST NEFISCAL',
          'NU ESTE BON FISCAL',
          'Cafea test  1 x 20.00 RON',
          'TOTAL TEST: 20.00 RON',
          'FARA INCASARE / FARA VANZARE IN ERP',
        ],
      );
  stdout.writeln('${result.outcome.name}: ${result.message}');
  if (result.outcome != CommandOutcome.succeeded) exitCode = 1;
}
