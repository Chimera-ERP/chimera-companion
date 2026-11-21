import 'dart:async';
import 'dart:io';
import 'connection.dart';
import 'contracts.dart';
import 'datecs_gateway_protocol.dart';
import 'datecs_rou_adapter.dart';
import 'tcp_transport.dart';
import 'fiscal_byte_session.dart';

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
           ((endpoint) => FiscalByteSession.connectWithTimeouts(
             endpoint,
             replyTimeout: const Duration(seconds: 2),
           )),
       _printSessions =
           sessions ??
           ((endpoint) => FiscalByteSession.connectWithTimeouts(
             endpoint,
             replyTimeout: const Duration(seconds: 60),
           )),
       _legacyProbe =
           legacyProbe ?? (() => DatecsRouAdapter.probeEndpoint(endpoint));
  final FiscalEndpoint endpoint;
  final DatecsProfile profile;
  final SessionFactory _sessions;
  final SessionFactory _printSessions;
  final Future<Map<String, Object?>> Function() _legacyProbe;
  String get _link => switch (endpoint) {
    FiscalSerialEndpoint(:final transport) => transport == 'usb' ? 'USB' : 'Bluetooth',
    LanEndpoint() => 'TCP',
  };
  int _nextSequence() =>
      DatecsGatewayProtocol.nextSequence(endpoint.key);

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

  /// Romanian FP_Protocol_RO, command 50. The seven tax slots precede the timestamp.
  Future<Map<String, double>> readMxVatRates() async {
    final session = await _sessions(endpoint);
    try {
      final fields = await _command(session, 50, '');
      if (fields.length != 10 ||
          !RegExp(r'^\d+$').hasMatch(fields[1]) ||
          fields.last.isEmpty) {
        throw const FormatException('Invalid Romanian Datecs VAT response');
      }
      final rates = <String, double>{};
      for (var i = 0; i < 7; i++) {
        final value = fields[i + 2];
        if (!RegExp(r'^\d{1,3}(?:\.\d{1,2})?$').hasMatch(value)) {
          throw const FormatException('Invalid Datecs VAT rate');
        }
        final rate = double.parse(value);
        if (rate < 100) {
          rates[String.fromCharCode(65 + i)] = rate;
        } else if (rate != 100 && rate != 100.01 && rate != 100.02) {
          throw const FormatException('Unknown Datecs VAT category');
        }
        // Exempt, other taxes and disabled slots do not encode a numeric rate.
      }
      return rates;
    } finally {
      await session.close();
    }
  }

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
              '$_link conectat · Datecs ASCII/MX · ${state[1] == '0' ? 'document închis' : 'document deschis (${state[1]})'}${_printerReady(statusBits) ? '' : ' · ECR are o eroare (hârtie/capac/imprimare)'}',
          payments: payments,
        );
      } on DatecsCommandException catch (error) {
        return DatecsInspection(
          connected: true,
          profile: DatecsProfile.asciiMx,
          ready: false,
          description:
              '$_link conectat · Datecs ASCII/MX · eroare ECR ${error.code}',
        );
      } on SocketException catch (error) {
        detail = '$_link: ${error.osError?.message ?? error.message}';
      } on TimeoutException {
        detail = '$_link conectat, fără răspuns ASCII/MX în 2 secunde';
      } catch (error) {
        detail =
            '$_link conectat, răspuns ASCII/MX invalid (${error.runtimeType})';
      } finally {
        await session?.close();
      }
    }
    if (profile == DatecsProfile.legacyRou || (profile == DatecsProfile.auto && endpoint is LanEndpoint)) {
      try {
        final legacy = await _legacyProbe();
        if (legacy['protocolConfirmed'] == true) {
          return DatecsInspection(
            connected: true,
            profile: DatecsProfile.legacyRou,
            ready: legacy['ready'] == true,
            description:
                '$_link conectat · Datecs ROU vechi · ${legacy['description']}',
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
      description: '${endpoint.label} · $detail',
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
            : 'Conexiunea $_link nu a putut fi deschisă.',
      );
    } finally {
      await session?.close();
    }
  }
}
