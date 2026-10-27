import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import '../companion_app_bar.dart';
import 'console_service.dart';

class ConsolePage extends StatefulWidget {
  const ConsolePage({super.key, required this.service, this.embedded = false});
  final ConsoleService service;
  final bool embedded;
  @override
  State<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends State<ConsolePage> {
  List<Map<String, dynamic>>? devices;
  String? error;
  bool scanning = false;
  Future<void> scan() async {
    setState(() {
      scanning = true;
      error = null;
    });
    try {
      final found = await widget.service.devices();
      if (mounted) setState(() => devices = found);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Accesul USB nu este disponibil pe acest dispozitiv.',
        );
      }
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final s = widget.service;
        return Padding(
          padding: widget.embedded ? EdgeInsets.zero : const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                s.connecting
                    ? 'Conectare…'
                    : s.connected
                    ? 'Ulanzi conectată'
                    : 'Consolă USB',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                s.leased || s.testing
                    ? s.title
                    : 'Conectează prin USB OTG, apoi selectează acest Companion în KDS.',
              ),
              if (s.testing) ...[
                const SizedBox(height: 8),
                const Text('5 ↑ · 10 ↓'),
              ],
              if (s.lastKey != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Tasta ${s.lastKey}',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
              if (s.error ?? error case final String message)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(message),
                ),
              const SizedBox(height: 20),
              if (s.connected)
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FButton(
                      onPress: s.leased
                          ? null
                          : s.testing
                          ? s.stopTest
                          : s.startTest,
                      child: Text(
                        s.testing ? 'Încheie proba' : 'Probă pictograme',
                      ),
                    ),
                    FButton(
                      onPress: s.disconnect,
                      child: const Text('Deconectează'),
                    ),
                  ],
                )
              else
                FButton(
                  onPress: s.connecting || scanning ? null : scan,
                  child: Text(scanning ? 'Se caută…' : 'Caută consola'),
                ),
              if (devices != null && !s.connected) ...[
                const SizedBox(height: 16),
                if (devices!.isEmpty)
                  const Text(
                    'Nicio consolă Ulanzi găsită. Verifică adaptorul OTG și alimentarea USB.',
                  ),
                for (final device in devices!)
                  FTile(
                    title: Text('${device['name']}'),
                    prefix: const Icon(Icons.keyboard),
                    suffix: const Icon(Icons.link),
                    onPress: s.connecting
                        ? null
                        : () => s.connect('${device['id']}'),
                  ),
              ],
            ],
          ),
        );
      },
    );
    return widget.embedded
        ? content
        : Scaffold(
            appBar: const CompanionAppBar(title: Text('Consolă KDS')),
            body: SafeArea(child: SingleChildScrollView(child: content)),
          );
  }
}
