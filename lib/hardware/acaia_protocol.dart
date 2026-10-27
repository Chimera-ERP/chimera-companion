// Protocol reference: gaggimate/esp-arduino-ble-scales v1.0.7 (MIT).
// See docs/vendor-provenance.md. Transport/framing is independently bounded.
class AcaiaProfile {
  const AcaiaProfile(
    this.service,
    this.notify,
    this.command, {
    this.umbra = false,
  });
  final String service, notify, command;
  final bool umbra;
  bool get supportsUnitWrite => service != profiles.first.service;
  // Modern: cmd10 setting0 = 2(g). Umbra: setting8 = 0(g).
  List<int> get gramsSetting => umbra ? [0, 8, 0] : [0, 0, 2];
  bool? statusIsGrams(List<int> payload) {
    final offset = umbra ? 4 : 2;
    if (payload.length <= offset) return null;
    final unit = payload[offset] & 0x7f;
    if (unit == (umbra ? 0 : 2)) return true;
    if (unit == (umbra ? 1 : 5)) return false;
    return null;
  }

  static const profiles = [
    AcaiaProfile(
      '00001820-0000-1000-8000-00805f9b34fb',
      '00002a80-0000-1000-8000-00805f9b34fb',
      '00002a80-0000-1000-8000-00805f9b34fb',
    ),
    AcaiaProfile(
      '49535343-fe7d-4ae5-8fa9-9fafd205e455',
      '49535343-1e4d-4bd9-ba61-23c647249616',
      '49535343-8841-43f4-a8d4-ecbe34729bb3',
    ),
    AcaiaProfile(
      '0000fe40-cc7a-482a-984a-7f2ed5b3e58f',
      '0000fe42-8e22-4541-9d4c-21edae82ed19',
      '0000fe41-8e22-4541-9d4c-21edae82ed19',
      umbra: true,
    ),
  ];
  static bool matches(String name, Iterable<String> services) =>
      [
        'ACAIA',
        'PYXIS',
        'LUNAR',
        'PEARL',
        'PROCH',
        'UMBRA',
      ].any(name.toUpperCase().startsWith) ||
      profiles.any(
        (p) => services.map((s) => s.toLowerCase()).contains(p.service),
      );
}

class AcaiaPacket {
  const AcaiaPacket(this.type, this.payload);
  final int type;
  final List<int> payload;
}

class AcaiaProtocol {
  final _buffer = <int>[];
  static List<int> frame(int type, List<int> payload) {
    var even = 0, odd = 0;
    for (var i = 0; i < payload.length; i++) {
      if (i.isEven) {
        even += payload[i];
      } else {
        odd += payload[i];
      }
    }
    return [0xef, 0xdd, type, ...payload, even & 255, odd & 255];
  }

  List<AcaiaPacket> accept(List<int> bytes) {
    if (_buffer.length + bytes.length > 2048) _buffer.clear();
    _buffer.addAll(bytes.take(2048));
    final packets = <AcaiaPacket>[];
    while (_buffer.length >= 4) {
      if (_buffer[0] != 0xef ||
          _buffer[1] != 0xdd ||
          _buffer[3] < 1 ||
          _buffer[3] > 64) {
        _buffer.removeAt(0);
        continue;
      }
      final size = _buffer[3] + 5;
      if (_buffer.length < size) break;
      final payload = _buffer.sublist(3, size - 2);
      final expected = frame(_buffer[2], payload);
      if (expected[size - 2] != _buffer[size - 2] ||
          expected.last != _buffer[size - 1]) {
        _buffer.removeAt(0);
        continue;
      }
      packets.add(AcaiaPacket(_buffer[2], payload));
      _buffer.removeRange(0, size);
    }
    return packets;
  }

  static String? weight(List<int> bytes, {bool umbra = false}) {
    if (bytes.length < 6 || bytes[4] < 1 || bytes[4] > 4) return null;
    final number = umbra
        ? (bytes[2] << 8) | bytes[3]
        : bytes[0] | (bytes[1] << 8);
    final precision = bytes[4];
    final digits = number.toString().padLeft(precision + 1, '0');
    return '${bytes[5] & 2 != 0 && number != 0 ? '-' : ''}${digits.substring(0, digits.length - precision)}.${digits.substring(digits.length - precision)}';
  }
}
