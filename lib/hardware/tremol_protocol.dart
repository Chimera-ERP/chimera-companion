import 'dart:convert';
import 'dart:math';
import 'connection.dart';

/// Tremol Romanian protocol 2601151250, chapters 1.1 and 1.2.
class TremolFrame {
  const TremolFrame(this.sequence, this.command, this.data, {this.error});
  final int sequence;
  final int? command;
  final List<int> data;
  final String? error;
  bool get isAck => command == null;
}

/// A standalone RO §1.2.1 control response declines the current frame.
class TremolCommandNotExecuted implements Exception {
  const TremolCommandNotExecuted(this.control)
    : assert(control == 0x0e || control == 0x15);

  final int control;

  @override
  String toString() => control == 0x15
      ? 'Tremol a respins formatul cadrului (NAK 15h).'
      : 'Tremol execută încă operația precedentă (RETRY 0Eh).';
}

class TremolProtocol {
  /// RO §2.5.1 specifies 11 columns. FP21 2.00TRP21_AC returns two
  /// uppercase letters and eight digits without padding on this command.
  static String manufacturingNumber(FiscalModel model, List<int> data) {
    final value = ascii.decode(data);
    final standard =
        value.length == 11 &&
        RegExp(r'^[A-Za-z0-9-]+$').hasMatch(value) &&
        RegExp(r'[A-Za-z1-9]').hasMatch(value);
    final fp21Short =
        model == FiscalModel.tremolFp21 &&
        value.length == 10 &&
        RegExp(r'^[A-Z]{2}[0-9]{8}$').hasMatch(value) &&
        value.substring(2) != '00000000';
    if (!standard && !fp21Short) {
      throw const FormatException(
        'Casa Tremol nu a furnizat o serie de fabricație utilizabilă.',
      );
    }
    return value;
  }

  // A USB/Bluetooth connection can reopen for each status, admission and write.
  // The printer remembers the previous command sequence across such opens.
  static final _serialSequences = <String, int>{};
  static int nextSerialSequence(String key) {
    final last = _serialSequences[key] ?? (0x20 + Random.secure().nextInt(128));
    return _serialSequences[key] = last == 0x9f ? 0x20 : last + 1;
  }

  static List<int> encode(int sequence, int command, List<int> data) {
    if (sequence < 0x20 ||
        sequence > 0x9f ||
        command < 0x20 ||
        command > 0x7f ||
        data.length > 220 ||
        data.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('Invalid Tremol frame');
    }
    final body = [data.length + 3 + 0x20, sequence, command, ...data];
    final sum = body.fold<int>(0, (sum, byte) => sum ^ byte);
    return [2, ...body, 0x30 + (sum >> 4), 0x30 + (sum & 15), 10];
  }

  static int? frameLength(List<int> bytes) {
    if (bytes.isEmpty) return null;
    if (bytes.first == 0x15 || bytes.first == 0x0e) {
      if (bytes.length != 1) {
        throw const FormatException('Unexpected bytes after Tremol control');
      }
      return 1;
    }
    if (bytes.first == 6) return 7;
    if (bytes.first != 2) {
      throw const FormatException('Unexpected Tremol control byte');
    }
    if (bytes.length < 2) return null;
    final length = bytes[1] - 0x20 + 4;
    if (length < 7 || length > 259) {
      throw const FormatException('Invalid Tremol length');
    }
    return length;
  }

  static TremolFrame decode(
    List<int> bytes, {
    required int sequence,
    required int command,
  }) {
    final length = frameLength(bytes);
    if (length == 1) throw TremolCommandNotExecuted(bytes.single);
    if (bytes.length != length || bytes.last != 10) {
      throw const FormatException('Truncated Tremol frame');
    }
    final ack = bytes.first == 6;
    final seq = bytes[ack ? 1 : 2];
    final actualCommand = ack ? null : bytes[3];
    if (seq != sequence || (!ack && actualCommand != command)) {
      throw const FormatException('Mismatched Tremol response');
    }
    final body = bytes.sublist(1, bytes.length - 3);
    final sum = body.fold<int>(0, (sum, byte) => sum ^ byte);
    if (bytes[bytes.length - 3] != 0x30 + (sum >> 4) ||
        bytes[bytes.length - 2] != 0x30 + (sum & 15)) {
      throw const FormatException('Invalid Tremol checksum');
    }
    final errors = ack && (bytes[2] != 0x30 || bytes[3] != 0x30)
        ? '${bytes[2] - 0x30}${bytes[3] - 0x30}'
        : null;
    return TremolFrame(
      seq,
      actualCommand,
      ack ? [] : bytes.sublist(4, bytes.length - 3),
      error: errors,
    );
  }
}
