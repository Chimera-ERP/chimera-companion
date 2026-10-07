import 'package:flutter/material.dart';
import 'debug_panel.dart';
import 'hardware/tremol_catalog.dart';

class TremolCatalogPage extends StatefulWidget {
  const TremolCatalogPage({super.key});
  @override
  State<TremolCatalogPage> createState() => _TremolCatalogPageState();
}

class _TremolCatalogPageState extends State<TremolCatalogPage> {
  final _endpoint = TextEditingController(text: 'http://127.0.0.1:4444');
  List<TremolCommandDefinition> _commands = [];
  bool _loading = false;
  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    setState(() => _loading = true);
    debugLog('Citesc catalogul Tremol…');
    try {
      final commands = await TremolCatalogClient(
        Uri.parse(_endpoint.text.trim()),
      ).discover();
      if (mounted) setState(() => _commands = commands);
      debugLog(
        '${commands.length} definiții citite. Catalogul nu confirmă conexiunea cu ECR-ul.',
      );
    } catch (_) {
      debugLog('Catalog Tremol indisponibil. Verifică adresa serviciului.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => DebugScaffold(
    title: 'Catalog Tremol',
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Diagnostic Direct API',
          style: TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _endpoint,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Adresa serviciului local Tremol',
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _loading ? null : _discover,
          child: Text(_loading ? 'Se citește…' : 'Citește catalogul'),
        ),
        for (final command in _commands)
          ExpansionTile(
            title: Text(command.name),
            subtitle: Text(command.description),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(command.definition),
              ),
            ],
          ),
      ],
    ),
  );
}
