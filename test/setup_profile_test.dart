import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/setup_profile.dart';

void main() {
  test(
    'profiles keep security steps and only relevant optional peripherals',
    () {
      expect(setupSteps(SetupProfile.pos, {}), [5, 0, 1, 2, 3, 6, 4]);
      for (final p in [SetupProfile.kds, SetupProfile.pds]) {
        expect(setupSteps(p, {}), [5, 0, 1, 6, 7, 4]);
      }
      expect(setupSteps(SetupProfile.custom, {}), [5, 0, 1, 4]);
      expect(setupSteps(SetupProfile.custom, {7, 2, 999}), [5, 0, 1, 2, 7, 4]);
    },
  );
}
