import 'dart:convert';
import 'dart:math';

/// Port of Chimera-ERP/chimera-pos-gateway @ cc0f01f command-framer.ts.
/// This is the gateway's Z-prefixed ASCII profile, NOT the Romanian binary SDK
/// protocol. Keep profiles explicit instead of assuming every DP-25 is identical.
class DatecsGatewayProtocol {
  static final _sequences = <String, int>{};
  static int nextSequence(String endpoint) {
    final last = _sequences[endpoint] ?? (0x20 + Random.secure().nextInt(0x60));
    return _sequences[endpoint] = last >= 0x7f ? 0x20 : last + 1;
  }

  static List<int> nibbles(int value) {
    if (value < 0 || value > 65535) {
      throw ArgumentError('Datecs nibble overflow');
    }
    return [
      for (final shift in [12, 8, 4, 0]) 0x30 + ((value >> shift) & 15),
    ];
  }

  static int _number(List<int> bytes) {
    if (bytes.any((byte) => byte < 0x30 || byte > 0x3f)) {
      throw const FormatException('Invalid Datecs nibbles');
    }
    return bytes.fold<int>(0, (value, byte) => (value << 4) | (byte - 0x30));
  }

  static List<int> encode(int command, String payload, {int sequence = 0x5a}) {
    if (command < 0 ||
        command > 65535 ||
        payload.codeUnits.any(
          (byte) => byte > 126 || (byte < 32 && byte != 9),
        )) {
      throw ArgumentError('Invalid gateway ASCII payload');
    }
    if (sequence < 0x20 || sequence > 0xff) {
      throw ArgumentError('Invalid Datecs sequence');
    }
    final message = [sequence, ...nibbles(command), ...ascii.encode(payload)];
    final body = [...nibbles(message.length + 5 + 0x20), ...message, 5];
    return [
      1,
      ...body,
      ...nibbles(body.fold<int>(0, (sum, byte) => sum + byte)),
      3,
    ];
  }

  static int? frameLength(List<int> bytes) {
    if (bytes.isEmpty) return null;
    if (bytes.first != 1) {
      throw const FormatException('Unexpected Datecs control byte');
    }
    if (bytes.length < 5) return null;
    final length = _number(bytes.sublist(1, 5)) - 0x20 + 6;
    if (length < 11 || length > 4096) {
      throw const FormatException('Invalid Datecs length');
    }
    return length;
  }

  static List<String> decode(List<int> bytes, {int? sequence, int? command}) {
    if (bytes.length != frameLength(bytes) ||
        bytes.last != 3 ||
        bytes[bytes.length - 6] != 5) {
      throw const FormatException('Invalid gateway Datecs framing');
    }
    final actual = bytes
        .sublist(1, bytes.length - 5)
        .fold<int>(0, (sum, byte) => sum + byte);
    if (_number(bytes.sublist(bytes.length - 5, bytes.length - 1)) != actual) {
      throw const FormatException('Datecs checksum mismatch');
    }
    var start = 5;
    var end = bytes.length - 6;
    if (sequence != null && command != null) {
      if (end < 10 ||
          bytes[5] != sequence ||
          _number(bytes.sublist(6, 10)) != command) {
        throw const FormatException('Mismatched Datecs sequence or command');
      }
      start = 10;
      final separator = bytes.indexOf(4, start);
      if (separator < 0 || end - separator != 9) {
        throw const FormatException('Missing Datecs status bytes');
      }
      end = separator;
    }
    final text = latin1.decode(bytes.sublist(start, end));
    final fields = text.split('\t');
    if (fields.isNotEmpty && fields.last.isEmpty) fields.removeLast();
    if (fields.isEmpty || fields.first != '0') {
      throw DatecsCommandException(
        fields.isEmpty ? 'empty response' : fields.first,
      );
    }
    return fields;
  }
}

class DatecsCommandException implements Exception {
  const DatecsCommandException(this.code);
  final String code;
  @override
  String toString() => 'Datecs error: $code';
}
