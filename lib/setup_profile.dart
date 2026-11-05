enum SetupProfile { pos, kds, pds, custom }

enum SetupAudience { front, back, custom }

SetupAudience audienceFor(SetupProfile profile) => switch (profile) {
  SetupProfile.pos => SetupAudience.front,
  SetupProfile.kds || SetupProfile.pds => SetupAudience.back,
  SetupProfile.custom => SetupAudience.custom,
};

List<SetupProfile> profilesFor(SetupAudience audience) => switch (audience) {
  SetupAudience.front => [SetupProfile.pos, SetupProfile.custom],
  SetupAudience.back => [
    SetupProfile.kds,
    SetupProfile.pds,
    SetupProfile.custom,
  ],
  SetupAudience.custom => SetupProfile.values,
};

Set<int> equipmentFor(SetupAudience audience) => switch (audience) {
  SetupAudience.front => {2, 3, 6, 9},
  SetupAudience.back => {6, 7, 10},
  SetupAudience.custom => {2, 3, 6, 7, 9, 10},
};

Set<int> defaultEquipment(SetupProfile profile) => switch (profile) {
  SetupProfile.pos => {2, 3, 6},
  SetupProfile.kds || SetupProfile.pds => {6, 7, 10},
  SetupProfile.custom => {2, 3, 6, 7, 9, 10},
};

/// Persisted step IDs and direct hardware links remain stable.
List<int> setupSteps(
  SetupProfile profile,
  Set<int> custom, {
  SetupAudience? audience,
  Set<int>? equipment,
}) => [
  0,
  5,
  8,
  1,
  for (final id in [2, 3, 6, 7, 9, 10])
    if ((equipment ??
                (profile == SetupProfile.custom
                    ? custom
                    : defaultEquipment(profile)))
            .contains(id) &&
        (audience == null || equipmentFor(audience).contains(id)))
      id,
  4,
];
