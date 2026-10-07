import 'dart:async';
import 'dart:io';
import 'connection.dart';
import 'contracts.dart';
import 'datecs_gateway_protocol.dart';
import 'datecs_rou_adapter.dart';
import 'tcp_transport.dart';

enum DatecsProfile { auto, asciiMx, legacyRou }

class DatecsInspection {
  const DatecsInspection({
    required this.connected,
    required this.profile,
    required this.ready,
    required this.description,
    this.payments = const [],
  });
  final bool connected;
  final DatecsProfile profile;
  final bool ready;
  final String description;
  final List<Map<String, dynamic>> payments;
}

/// Protocol detection uses only read commands. Printing always uses the confirmed profile.
class DatecsDeviceClient {
  DatecsDeviceClient(
    this.endpoint, {
    this.profile = DatecsProfile.auto,
    SessionFactory? sessions,
    Future<Map<String, Object?>> Function()? legacyProbe,
  }) : _sessions =
           sessions ??
           ((endpoint) => TcpByteSession.connectWithTimeouts(
             endpoint,
             replyTimeout: const Duration(seconds: 2),
           )),
       _printSessions =
           sessions ??
           ((endpoint) => TcpByteSession.connectWithTimeouts(
             endpoint,
             replyTimeout: const Duration(seconds: 60),
           )),
       _legacyProbe =
           legacyProbe ?? (() => DatecsRouAdapter.probeEndpoint(endpoint));
  final LanEndpoint endpoint;
  final DatecsProfile profile;
  final SessionFactory _sessions;
  final SessionFactory _printSessions;
  final Future<Map<String, Object?>> Function() _legacyProbe;
  int _nextSequence() =>
      DatecsGatewayProtocol.nextSequence('${endpoint.host}:${endpoint.port}');

  Future<List<String>> _command(
    ByteSession session,
    int command,
    String payload,
  ) async {
    final sequence = _nextSequence();
    return DatecsGatewayProtocol.decode(
      await session.exchange(
        DatecsGatewayProtocol.encode(command, payload, sequence: sequence),
        DatecsGatewayProtocol.frameLength,
      ),
      sequence: sequence,
      command: command,
    );
  }

  Future<(List<String>, List<int>)> _state(ByteSession session) async {
    final sequence = _nextSequence();
    final bytes = await session.exchange(
      DatecsGatewayProtocol.encode(76, '', sequence: sequence),
      DatecsGatewayProtocol.frameLength,
    );
    final fields = DatecsGatewayProtocol.decode(
      bytes,
      sequence: sequence,
      command: 76,
    );
    return (fields, bytes.sublist(bytes.length - 14, bytes.length - 6));
  }

  bool _printerReady(List<int> bits) =>
      (bits[0] & 0x70) == 0 && (bits[2] & 0x05) == 0;

  Future<DatecsInspection> inspect({bool readPayments = false}) async {
    ByteSession? session;
    var connected = false;
    var detail = '';
    if (profile != DatecsProfile.legacyRou) {
      try {
        session = await _sessions(endpoint);
        connected = true;
        final (state, statusBits) = await _state(session);
        if (state.length < 2 || !RegExp(r'^[0-9]$').hasMatch(state[1])) {
          throw const FormatException('Răspuns 76 invalid');
        }
        final payments = <Map<String, dynamic>>[];
        if (readPayments) {
          for (var index = 0; index < 6; index++) {
            try {
              // Blank value is the read-only variant of command 255.
              final response = await _command(
                session,
                255,
                'PayName\t$index\t\t',
              );
              if (response.length > 1 && response[1].trim().isNotEmpty) {
                payments.add({'code': '$index', 'name': response[1].trim()});
              }
            } on DatecsCommandException {
              continue;
            } catch (_) {
              break;
            }
          }
        }
        return DatecsInspection(
          connected: true,
          profile: DatecsProfile.asciiMx,
          ready: state[1] == '0' && _printerReady(statusBits),
          description:
              'TCP conectat · Datecs ASCII/MX · ${state[1] == '0' ? 'document închis' : 'document deschis (${state[1]})'}${_printerReady(statusBits) ? '' : ' · ECR are o eroare (hârtie/capac/imprimare)'}',
          payments: payments,
        );
      } on DatecsCommandException catch (error) {
        return DatecsInspection(
          connected: true,
          profile: DatecsProfile.asciiMx,
          ready: false,
          description:
              'TCP conectat · Datecs ASCII/MX · eroare ECR ${error.code}',
        );
      } on SocketException catch (error) {
        detail = 'TCP: ${error.osError?.message ?? error.message}';
      } on TimeoutException {
        detail = 'TCP conectat, fără răspuns ASCII/MX în 2 secunde';
      } catch (error) {
        detail =
            'TCP conectat, răspuns ASCII/MX invalid (${error.runtimeType})';
      } finally {
        await session?.close();
      }
    }
    if (profile != DatecsProfile.asciiMx) {
      try {
        final legacy = await _legacyProbe();
        if (legacy['protocolConfirmed'] == true) {
          return DatecsInspection(
            connected: true,
            profile: DatecsProfile.legacyRou,
            ready: legacy['ready'] == true,
            description:
                'TCP conectat · Datecs ROU vechi · ${legacy['description']}',
          );
        }
        detail =
            '$detail · ${legacy['description'] ?? 'fără răspuns ROU vechi'}';
      } catch (_) {
        detail = '$detail · fără răspuns ROU vechi';
      }
    }
    return DatecsInspection(
      connected: connected,
      profile: DatecsProfile.auto,
      ready: false,
      description: '${endpoint.host}:${endpoint.port} · $detail',
    );
  }

  Future<HardwareResult> printXReport() => printReport(closeDay: false);

  Future<HardwareResult> printReport({required bool closeDay}) async {
    final detected = await inspect();
    if (detected.profile == DatecsProfile.legacyRou) {
      return DatecsRouAdapter.printReport(endpoint, closeDay: closeDay);
    }
    if (detected.profile != DatecsProfile.asciiMx || !detected.ready) {
      return HardwareResult(
        CommandOutcome.rejected,
        message: detected.description,
      );
    }
    ByteSession? session;
    var dispatched = false;
    try {
      session = await _printSessions(endpoint);
      final (current, bits) = await _state(session);
      if (current.length < 2 || current[1] != '0' || !_printerReady(bits)) {
        return const HardwareResult(
          CommandOutcome.rejected,
          message: 'Datecs are un document deschis sau o eroare de imprimare.',
        );
      }
      dispatched = true;
      // MX uses X + TAB; legacy ROU uses 2. Never fall back after a print dispatch.
      final response = await _command(session, 69, closeDay ? 'Z\t' : 'X\t');
      return HardwareResult(
        CommandOutcome.succeeded,
        reference: response.length > 1 ? response[1] : null,
        message: 'Raport ${closeDay ? 'Z' : 'X'} confirmat · Datecs ASCII/MX.',
      );
    } on DatecsCommandException catch (error) {
      return HardwareResult(
        CommandOutcome.rejected,
        message: 'Raport ${closeDay ? 'Z' : 'X'} refuzat de ECR: ${error.code}',
      );
    } catch (_) {
      return HardwareResult(
        dispatched ? CommandOutcome.unknown : CommandOutcome.rejected,
        message: dispatched
            ? 'Răspuns raport pierdut. Verifică hârtia înainte de retransmitere.'
            : 'Conexiunea TCP nu a putut fi deschisă.',
      );
    } finally {
      await session?.close();
    }
  }
}
