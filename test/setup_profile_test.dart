import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/setup_profile.dart';

void main() {
  test(
    'profiles keep security steps and only relevant optional peripherals',
    () {
      expect(setupSteps(SetupProfile.pos, {}), [0, 5, 8, 1, 2, 3, 6, 4]);
      for (final p in [SetupProfile.kds, SetupProfile.pds]) {
        expect(setupSteps(p, {}), [0, 5, 8, 1, 6, 7, 10, 4]);
      }
      expect(setupSteps(SetupProfile.custom, {}), [0, 5, 8, 1, 4]);
      expect(setupSteps(SetupProfile.custom, {7, 2, 999}), [
        0,
        5,
        8,
        1,
        2,
        7,
        4,
      ]);
    },
  );
  test(
    'audience filters stale peripheral selections but custom retains all supported devices',
    () {
      final devices = {2, 3, 6, 7, 9, 10, 999};
      expect(
        setupSteps(
          SetupProfile.kds,
          devices,
          audience: SetupAudience.back,
          equipment: devices,
        ),
        [0, 5, 8, 1, 6, 7, 10, 4],
      );
      expect(
        setupSteps(
          SetupProfile.pos,
          devices,
          audience: SetupAudience.front,
          equipment: devices,
        ),
        [0, 5, 8, 1, 2, 3, 6, 9, 4],
      );
      expect(
        setupSteps(
          SetupProfile.custom,
          devices,
          audience: SetupAudience.custom,
          equipment: devices,
        ),
        [0, 5, 8, 1, 2, 3, 6, 7, 9, 10, 4],
      );
      expect(
        profilesFor(SetupAudience.back),
        isNot(contains(SetupProfile.pos)),
      );
      expect(
        profilesFor(SetupAudience.front),
        isNot(contains(SetupProfile.kds)),
      );
    },
  );
}
