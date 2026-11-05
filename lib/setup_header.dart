import 'package:flutter/material.dart';
import 'companion_scene.dart';

const setupStepTitles = [
  'Conectare la Chimera',
  'Pregătim conexiunea',
  'Casa de marcat',
  'Terminal de plată',
  'Verificare finală',
  'Cum folosești Companion?',
  'Cântar',
  'Imprimantă producție',
  'Alege echipamentele',
  'Ecran client',
  'Tastatură custom',
];

CompanionSceneState setupSceneFor(int step, CompanionSceneState audience) =>
    switch (step) {
      0 => CompanionSceneState.welcome,
      1 => CompanionSceneState.connecting,
      2 => CompanionSceneState.fiscal,
      3 => CompanionSceneState.payment,
      4 => CompanionSceneState.ready,
      6 => CompanionSceneState.scale,
      7 => CompanionSceneState.printer,
      8 => CompanionSceneState.custom,
      9 => CompanionSceneState.display,
      10 => CompanionSceneState.keyboard,
      _ => audience,
    };

/// Keep forms readable on a POS screen, without squeezing short landscape phones.
class SetupFrame extends StatelessWidget {
  const SetupFrame({
    super.key,
    required this.step,
    required this.child,
    this.steps = const [0, 1, 2, 3, 4],
  });
  final List<int> steps;
  final int step;
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final form = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: child,
      );
      if (constraints.maxWidth < 1100 || constraints.maxHeight < 500) {
        return Center(child: form);
      }
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1060),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 300,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 24, 24, 24),
                  children: [
                    for (var i = 0; i < steps.length; i++)
                      ListTile(
                        selected: steps[i] == step,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        leading: i < steps.indexOf(step)
                            ? const Icon(Icons.check, size: 20)
                            : Icon(
                                steps[i] == step
                                    ? Icons.radio_button_checked
                                    : Icons.circle_outlined,
                                size: 20,
                              ),
                        title: Text(setupStepTitles[steps[i]]),
                      ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: form),
            ],
          ),
        ),
      );
    },
  );
}

/// The step owns its operation; the wizard only places its action in the footer.
class SetupAction {
  const SetupAction(this.label, this.run, {this.busy = false, this.scene});
  final CompanionSceneState? scene;
  final String label;
  final VoidCallback? run;
  final bool busy;
}

class SetupHeader extends StatelessWidget {
  const SetupHeader({
    super.key,
    required this.step,
    this.showScene = true,
    this.scene = CompanionSceneState.custom,
    this.steps = const [0, 1, 2, 3, 4],
  });
  final List<int> steps;
  final int step;
  final CompanionSceneState scene;
  final bool showScene;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showScene && step != 0 && step != 1) ...[
          CompanionScene(scene: setupSceneFor(step, scene)),
          const SizedBox(height: 24),
        ],
        Text(
          setupStepTitles[step],
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        if (MediaQuery.sizeOf(context).height >= 460) ...[
          const SizedBox(height: 8),
          Text(
            const [
              'Introdu PIN-ul generat pentru locația ta.',
              'Conexiunea cu POS-ul se securizează automat.',
              'Caută în rețea sau introdu adresa. Poți configura mai târziu.',
              'Pe acest telefon sau pe alt dispozitiv. Pas opțional.',
              'Verifică apoi conexiunea reală din browserul POS.',
              'Unde va lucra acest Companion?',
              'Alege conexiunea și cântarul. Pas opțional.',
              'Alege conexiunea și imprimanta. Pas opțional.',
              'Selectează ce folosești aici. Poți reveni oricând.',
              'Afișează coșul și prezentarea locației.',
              'Conectează tastatura USB pentru KDS sau PDS. Pas opțional.',
            ][step],
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ],
      ],
    ),
  );
}

class SetupCard extends StatelessWidget {
  const SetupCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 20), child: child);
}

/// Shared selection row for audience, application and other setup choices.
class SetupChoice extends StatelessWidget {
  const SetupChoice({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String title, description;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      selected: selected,
      child: Material(
        color: selected ? const Color(0xff0b1730) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          leading: Icon(
            icon,
            size: 24,
            color: selected ? const Color(0xff60a5fa) : null,
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(description),
          trailing: Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            size: 20,
            color: selected ? const Color(0xff60a5fa) : null,
          ),
          onTap: onTap,
        ),
      ),
    ),
  );
}
