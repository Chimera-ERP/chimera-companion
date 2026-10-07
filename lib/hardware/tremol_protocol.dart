/// Tremol Romanian protocol 2601151250, chapters 1.1 and 1.2.
class TremolFrame {
  const TremolFrame(this.sequence, this.command, this.data, {this.error});
  final int sequence;
  final int? command;
  final List<int> data;
  final String? error;
  bool get isAck => command == null;
}

class TremolProtocol {
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
    if (bytes.length != frameLength(bytes) || bytes.last != 10) {
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
