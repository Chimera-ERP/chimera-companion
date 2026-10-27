// Protocol reference: MultiMote/niimbluelib a9bc3f5; see vendor-provenance.md.
class NiimbotPacket {
  const NiimbotPacket(this.command, this.data);
  final int command;
  final List<int> data;
  List<int> encode() {
    if (data.length > 255) throw const FormatException('Packet too large');
    final checksum = data.fold(command ^ data.length, (a, b) => a ^ b);
    return [
      if (command == 0xc1) 3,
      0x55,
      0x55,
      command,
      data.length,
      ...data,
      checksum,
      0xaa,
      0xaa,
    ];
  }
}

class NiimbotDecoder {
  final _buffer = <int>[];
  List<NiimbotPacket> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final packets = <NiimbotPacket>[];
    while (_buffer.length >= 2) {
      if (_buffer[0] != 0x55 || _buffer[1] != 0x55) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < 4) break;
      final length = _buffer[3], end = length + 7;
      if (_buffer.length < end) break;
      final data = _buffer.sublist(4, 4 + length);
      if (_buffer[end - 2] != 0xaa ||
          _buffer[end - 1] != 0xaa ||
          data.fold(_buffer[2] ^ length, (a, b) => a ^ b) != _buffer[end - 3]) {
        _buffer.removeAt(0);
        continue;
      }
      packets.add(NiimbotPacket(_buffer[2], data));
      _buffer.removeRange(0, end);
    }
    return packets;
  }
}

class NiimbotModel {
  const NiimbotModel(this.id, this.name, this.width, this.b1, this.density);
  final int id, width, density;
  final String name;
  final bool b1;
  static const supported = [
    NiimbotModel(4096, 'B1', 384, true, 3),
    NiimbotModel(771, 'B21 C2B', 384, true, 3),
    NiimbotModel(775, 'B21 C2B', 384, true, 3),
    NiimbotModel(777, 'B21S', 384, false, 3),
    NiimbotModel(2560, 'D101', 192, true, 2),
    NiimbotModel(2304, 'D110', 96, false, 2),
    NiimbotModel(2305, 'D110', 96, false, 2),
  ];
  static NiimbotModel fromId(int id) => supported.firstWhere(
    (m) => m.id == id,
    orElse: () => throw UnsupportedError(
      'NIIMBOT model $id: protocol neimplementat încă.',
    ),
  );
}

List<int> niimbotU16(int value) => [value >> 8 & 255, value & 255];

NiimbotPacket niimbotRow(int row, List<int> bits, int headWidth) {
  final parts = [0, 0, 0];
  final chunk = headWidth ~/ 8 ~/ 3;
  var total = 0;
  for (var i = 0; i < bits.length; i++) {
    for (var bit = 0; bit < 8; bit++) {
      if (bits[i] & (1 << bit) != 0) {
        total++;
        if (bits.length <= chunk * 3) parts[i ~/ chunk]++;
      }
    }
  }
  if (total == 0) return NiimbotPacket(0x84, [...niimbotU16(row), 1]);
  final counts = bits.length <= chunk * 3
      ? parts
      : [0, total & 255, total >> 8];
  return NiimbotPacket(0x85, [...niimbotU16(row), ...counts, 1, ...bits]);
}
