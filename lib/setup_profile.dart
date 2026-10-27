enum SetupProfile { pos, kds, pds, custom }

// Existing step IDs remain stable for saved progress and direct configuration links.
List<int> setupSteps(SetupProfile profile, Set<int> custom) => [
  5,
  0,
  1,
  ...switch (profile) {
    SetupProfile.pos => [2, 3, 6],
    SetupProfile.kds || SetupProfile.pds => [6, 7],
    SetupProfile.custom => [
      for (final id in [2, 3, 6, 7])
        if (custom.contains(id)) id,
    ],
  },
  4,
];
