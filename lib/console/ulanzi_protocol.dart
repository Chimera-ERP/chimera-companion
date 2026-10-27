import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// D200 framing: command BE16, payload length LE32. Only the first packet has a header.
class UlanziProtocol {
  static const vendor = 0x2207, product = 0x0019, packetSize = 1024;
  static List<Uint8List> packets(int command, List<int> payload) {
    if (![1, 3, 6, 0x0b, 0x0d].contains(command) ||
        payload.length > 1024 * 1024) {
      throw ArgumentError('Unsupported console packet');
    }
    final first = Uint8List(packetSize);
    first[0] = 0x7c;
    first[1] = 0x7c;
    final header = ByteData.sublistView(first);
    header.setUint16(2, command, Endian.big);
    header.setUint32(4, payload.length, Endian.little);
    final initial = payload.length.clamp(0, 1016);
    first.setRange(8, 8 + initial, payload);
    return [
      first,
      for (var offset = initial; offset < payload.length; offset += 1024)
        Uint8List(packetSize)..setRange(
          0,
          (payload.length - offset).clamp(0, 1024),
          payload,
          offset,
        ),
    ];
  }

  static ({int index, bool pressed})? button(List<int> bytes) {
    if (bytes.length < 12 ||
        bytes[0] != 0x7c ||
        bytes[1] != 0x7c ||
        bytes[2] != 1 ||
        ![1, 2].contains(bytes[3]) ||
        bytes[9] > 12 ||
        ![0, 1].contains(bytes[11])) {
      return null;
    }
    return (index: bytes[9], pressed: bytes[11] == 1);
  }

  static int? command(List<int> bytes) =>
      bytes.length >= 8 && bytes[0] == 0x7c && bytes[1] == 0x7c
      ? bytes[2] * 256 + bytes[3]
      : null;
  static Uint8List screen(Map<int, Uint8List> icons) {
    final manifest = <String, Object?>{}, archive = Archive();
    final assets = <String>{};
    for (var i = 0; i < 13; i++) {
      final icon = icons[i];
      // Firmware image decoders can retain paths across full-screen uploads.
      // New pixels need a new path; identical blank keys can share one asset.
      final name = icon == null ? null : 'icons/${sha256.convert(icon)}.png';
      manifest['${i % 5}_${i ~/ 5}'] = {
        'State': 0,
        'ViewParam': [
          if (icon != null) {'Icon': name} else <String, Object?>{},
        ],
      };
      if (icon != null && assets.add(name!)) {
        archive.addFile(ArchiveFile(name, icon.length, icon));
      }
    }
    manifest['3_2'] = {
      'State': 0,
      'SmallViewMode': 1,
      'ViewParam': [<String, Object?>{}],
    };
    final json = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile('manifest.json', json.length, json));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}
