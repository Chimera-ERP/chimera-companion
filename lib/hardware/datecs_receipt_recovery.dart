import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'connection.dart';
import 'contracts.dart';
import 'datecs_gateway_protocol.dart';
import 'tcp_transport.dart';

typedef DatecsSend = Future<List<String>> Function(int command, String payload);

/// Current MX framing, with separate Romanian and Bulgarian response schemas.
/// The pre-MX 2014 binary SDK is not the Romanian DP-25mx protocol.
class DatecsReceiptRecovery {
  static List<String> markers(String commandId) {
    final hash = sha256.convert(utf8.encode(commandId)).toString();
    return [
      for (var i = 0; i < 4; i++)
        'CHM${i + 1}:${hash.substring(i * 16, (i + 1) * 16)}',
    ];
  }

  static Future<String> serial(DatecsSend send) async {
    return (await identity(send)).$1;
  }

  static Future<(String, String)> identity(DatecsSend send) async {
    final values = await send(123, '1\t');
    if (values.length < 3 ||
        !RegExp(r'^[A-Za-z0-9-]{4,32}$').hasMatch(values[1]) ||
        !RegExp(r'^[A-Za-z0-9-]{1,32}$').hasMatch(values[2])) {
      throw const FormatException('Datecs serial missing');
    }
    return (values[1], values[2]);
  }

  static bool number(String value, int max) {
    final parsed = int.tryParse(value);
    return RegExp(r'^[1-9][0-9]*$').hasMatch(value) &&
        parsed != null &&
        parsed <= max;
  }

  /// ROU returns seven fields, including RecReport before RecNumber. Never
  /// interpret it using the six-field Bulgarian offsets. Global lookup uses
  /// DocType=0, so RecReport is 0; resolve again by Z*10000+receipt, DocType=1.
  static Future<Map<String, String>?> journalIdentity(
    DatecsSend send,
    List<String> doc,
    Map<String, dynamic> evidence,
  ) async {
    final global = '${evidence['receiptNumber']}';
    if (doc.length == 7) {
      if (doc[1] != global ||
          doc[5] != '1' ||
          !number(doc[3], 9999) ||
          !number(doc[6], 2500) ||
          (doc[2] != '0' && doc[2] != doc[6]) ||
          (evidence['zNumber'] != null && evidence['zNumber'] != doc[6])) {
        return null;
      }
      final selected = await send(
        125,
        '0\t${int.parse(doc[6]) * 10000 + int.parse(doc[3])}\t1\t',
      );
      if (selected.length != 7 ||
          selected[1] != global ||
          selected[2] != doc[6] ||
          selected[3] != doc[3] ||
          selected[4] != doc[4] ||
          selected[5] != '1' ||
          selected[6] != doc[6]) {
        return null;
      }
      return {
        'receiptNumber': doc[3],
        'zNumber': doc[6],
        'documentNumber': global,
      };
    }
    // A recorded Romanian response must never downgrade to another schema.
    if (evidence['profile'] == 'rouMx' ||
        doc.length != 6 ||
        doc[1] != global ||
        doc[4] != '1' ||
        !number(doc[2], 9999999) ||
        !number(doc[5], 9999999)) {
      return null;
    }
    return {
      'receiptNumber': doc[2],
      'zNumber': doc[5],
      'documentNumber': global,
    };
  }

  static Future<HardwareResult> read(
    LanEndpoint endpoint,
    String commandId,
    Map<String, dynamic>? evidence, {
    SessionFactory? sessions,
  }) async {
    const unknown = HardwareResult(
      CommandOutcome.unknown,
      message: 'Bonul Datecs nu poate fi identificat sigur. Nu este retrimis.',
    );
    if (!['asciiMx', 'rouMx'].contains(evidence?['profile']) ||
        evidence?['commandId'] != commandId ||
        evidence?['closeAttempted'] != true ||
        !RegExp(
          r'^[1-9][0-9]{0,7}$',
        ).hasMatch('${evidence?['receiptNumber']}')) {
      return unknown;
    }
    ByteSession? session;
    try {
      session = await (sessions ?? TcpByteSession.connect)(endpoint);
      Future<List<String>> send(int command, String payload) async {
        final seq = DatecsGatewayProtocol.nextSequence(
          '${endpoint.host}:${endpoint.port}',
        );
        return DatecsGatewayProtocol.decode(
          await session!.exchange(
            DatecsGatewayProtocol.encode(command, payload, sequence: seq),
            DatecsGatewayProtocol.frameLength,
          ),
          sequence: seq,
          command: command,
        );
      }

      final (currentSerial, fiscalSerial) = await identity(send);
      if (currentSerial != evidence!['serialNumber']) return unknown;
      if (evidence['fiscalSerialNumber'] != null &&
          evidence['fiscalSerialNumber'] != fiscalSerial) {
        return unknown;
      }
      final state = await send(76, '');
      if (state.length < 2 || state[1] != '0') return unknown;
      // Select the exact global slip number, not the last receipt or a total.
      final doc = await send(125, '0\t${evidence['receiptNumber']}\t0\t');
      final document = await journalIdentity(send, doc, evidence);
      if (document == null) return unknown;
      final missing = markers(commandId).toSet();
      // Bounded read-only scan. No print (option 3), payment, close or cancel.
      for (var i = 0; i < 1024; i++) {
        final line = await send(125, '1\t');
        if (line.length != 2 || line[1].length > (doc.length == 7 ? 42 : 128)) {
          return unknown;
        }
        missing.remove(line[1].trim());
        if (missing.isEmpty) {
          return HardwareResult(
            CommandOutcome.succeeded,
            reference: document['receiptNumber'],
            message: 'Bon confirmat în jurnalul electronic Datecs.',
            fiscalIdentity: {
              'serialNumber': currentSerial,
              'fiscalSerialNumber': fiscalSerial,
              ...document,
            },
          );
        }
      }
      return unknown;
    } catch (_) {
      return unknown;
    } finally {
      await session?.close();
    }
  }
}
