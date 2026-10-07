import 'connection.dart';
import 'contracts.dart';
import 'datecs_gateway_protocol.dart';
import 'tcp_transport.dart';

class DatecsGatewayAdapter {
  DatecsGatewayAdapter(this.endpoint, {SessionFactory? sessions})
    : _sessions = sessions ?? TcpByteSession.connect;
  final LanEndpoint endpoint;
  final SessionFactory _sessions;
  bool _busy = false;

  /// Existing non-fiscal sequence from gateway: 38 -> 42 per line -> 39.
  Future<HardwareResult> printNonFiscal(List<String> lines,{String? claimToken}) async {
    if(claimToken!=null&&!RegExp(r'^[A-Za-z0-9]{12}$').hasMatch(claimToken))throw ArgumentError('Invalid claim token');
    if (lines.isEmpty ||
        lines.length > 100 ||
        lines.any(
          (line) =>
              line.length > 40 ||
              line.codeUnits.any((byte) => byte < 32 || byte > 126),
        )) {
      throw ArgumentError(
        'Non-fiscal lines must be printable ASCII, max 40 bytes',
      );
    }
    if (_busy) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Datecs ocupat',
      );
    }
    _busy = true;
    ByteSession? session;
    var dispatched = false;
    try {
      session = await _sessions(endpoint);
      for (final command in [
        (38, ''),
        ...lines.map((line) => (42, '$line\t\t\t\t\t\t')),
        if(claimToken!=null) (84,'3\t$claimToken\t'),
        (39, ''),
      ]) {
        dispatched = true;
        final sequence = DatecsGatewayProtocol.nextSequence(
          '${endpoint.host}:${endpoint.port}',
        );
        DatecsGatewayProtocol.decode(
          await session.exchange(
            DatecsGatewayProtocol.encode(
              command.$1,
              command.$2,
              sequence: sequence,
            ),
            DatecsGatewayProtocol.frameLength,
          ),
          sequence: sequence,
          command: command.$1,
        );
      }
      return HardwareResult(
        CommandOutcome.succeeded,
        message: 'Document nefiscal confirmat',
        fiscalIdentity:{'documentMode':'nonfiscal'},
      );
    } catch (_) {
      return HardwareResult(
        dispatched ? CommandOutcome.unknown : CommandOutcome.rejected,
        message: 'Verifică documentul pe Datecs înainte de retrimitere',
      );
    } finally {
      await session?.close();
      _busy = false;
    }
  }
}
