import 'package:flutter/material.dart';

const setupStepTitles = [
  'Conectare la Chimera',
  'Conexiune HTTPS locală',
  'Casa de marcat',
  'Terminal de plată',
  'Verificare finală',
];

/// Keep forms readable on a POS screen, without squeezing short landscape phones.
class SetupFrame extends StatelessWidget {
  const SetupFrame({super.key, required this.step, required this.child});
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
                    for (var i = 0; i < setupStepTitles.length; i++)
                      ListTile(
                        selected: i == step,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        leading: i < step
                            ? const Icon(Icons.check, size: 20)
                            : Text('${i + 1}'),
                        title: Text(setupStepTitles[i]),
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
  const SetupAction(this.label, this.run, {this.busy = false});
  final String label;
  final VoidCallback? run;
  final bool busy;
}

class SetupHeader extends StatelessWidget {
  const SetupHeader({super.key, required this.step});
  final int step;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${step + 1} din 5',
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Text(
          setupStepTitles[step],
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        if (MediaQuery.sizeOf(context).height >= 460) ...[
          const SizedBox(height: 8),
          Text(
            const [
              'Introdu adresa ERP și PIN-ul locației.',
              'Conexiunea cu POS-ul se securizează automat.',
              'Caută în rețea sau introdu adresa. Poți configura mai târziu.',
              'Pe acest telefon sau pe alt dispozitiv. Pas opțional.',
              'Verifică apoi conexiunea reală din browserul POS.',
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
