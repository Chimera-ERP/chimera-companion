import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/scale.dart';

void main() {
  final now = DateTime.utc(2026, 10, 21);
  ScaleReading reading({
    String net = '0.350',
    bool stable = true,
    bool overload = false,
    DateTime? at,
  }) => ScaleReading(
    deviceId: 'test-scale',
    net: net,
    unit: ScaleUnit.kg,
    stable: stable,
    overload: overload,
    observedAt: at ?? now,
  );
  test('preserves decimal precision and unit without invented gross/tare', () {
    final value = reading();
    expect(value.toJson()['net'], '0.350');
    expect(value.toJson()['unit'], 'kg');
    expect(value.toJson().containsKey('tare'), false);
    expect(value.usableAt(now), true);
  });
  test(
    'unstable, overloaded, zero, negative, future and stale readings cannot be accepted',
    () {
      for (final value in [
        reading(stable: false),
        reading(overload: true),
        reading(net: '0'),
        reading(net: '-1'),
        reading(at: now.add(const Duration(seconds: 1))),
        reading(at: now.subtract(const Duration(seconds: 3))),
      ]) {
        expect(value.usableAt(now), false);
      }
      expect(() => reading(net: 'NaN'), throwsArgumentError);
    },
  );
}
