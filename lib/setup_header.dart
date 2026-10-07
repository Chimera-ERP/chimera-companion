import 'package:flutter/material.dart';

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
          const [
            'Conectare la Chimera',
            'Conexiune HTTPS locală',
            'Casa de marcat',
            'Terminal de plată',
            'Verificare finală',
          ][step],
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          const [
            'Introdu adresa ERP și PIN-ul locației.',
            'Conexiunea cu POS-ul se securizează automat.',
            'Caută în rețea sau introdu adresa.',
            'Pe acest telefon sau pe alt dispozitiv. Pas opțional.',
            'Verifică apoi conexiunea reală din browserul POS.',
          ][step],
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
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
