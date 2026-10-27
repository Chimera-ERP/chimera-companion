import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/acaia_protocol.dart';

void main() {
  test(
    'identifies names and service-only advertisements, not unrelated devices',
    () {
      expect(AcaiaProfile.matches('LUNAR-123', []), isTrue);
      expect(
        AcaiaProfile.matches('', [AcaiaProfile.profiles.last.service]),
        isTrue,
      );
      expect(AcaiaProfile.matches('Speaker', []), isFalse);
    },
  );
  test(
    'wire checksum matches known heartbeat, fragmented and concatenated frames',
    () {
      expect(AcaiaProtocol.frame(0, [2, 0]), [0xef, 0xdd, 0, 2, 0, 2, 0]);
      final parser = AcaiaProtocol();
      final frame = AcaiaProtocol.frame(0x0c, [8, 5, 0xac, 0x0d, 0, 0, 1, 0]);
      for (final byte in frame.take(frame.length - 1)) {
        expect(parser.accept([byte]), isEmpty);
      }
      final packets = parser.accept([frame.last, ...frame]);
      expect(packets, hasLength(2));
      expect(AcaiaProtocol.weight(packets.first.payload.sublist(2)), '350.0');
    },
  );
  test('rejects checksum corruption, resynchronizes and bounds junk', () {
    final parser = AcaiaProtocol();
    final good = AcaiaProtocol.frame(8, [3, 80, 2]);
    final bad = [...good]..[good.length - 1] ^= 1;
    expect(parser.accept([1, 2, ...bad, ...good]), hasLength(1));
    parser.accept(List.filled(5000, 0));
    expect(parser.accept(good), hasLength(1));
  });
  test(
    'preserves sign and precision across standard and Umbra byte ordering',
    () {
      expect(AcaiaProtocol.weight([123, 0, 0, 0, 2, 2]), '-1.23');
      expect(AcaiaProtocol.weight([0, 0, 0, 123, 3, 0], umbra: true), '0.123');
      expect(AcaiaProtocol.weight([1, 0, 0, 0, 5, 0]), isNull);
      expect(AcaiaProtocol.weight([1, 0]), isNull);
    },
  );
}
