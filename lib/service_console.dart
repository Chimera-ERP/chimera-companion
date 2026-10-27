import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'local_bridge.dart';
import 'companion_app_bar.dart';

class ServiceConsole extends StatefulWidget {
  const ServiceConsole({super.key, required this.bridge});
  final LocalBridge bridge;
  @override
  State<ServiceConsole> createState() => _ServiceConsoleState();
}

class _ServiceConsoleState extends State<ServiceConsole> {
  final command = TextEditingController(text: '20');
  final payload = TextEditingController();
  final output = <String>[];
  bool enabled = false, hex = false, busy = false;
  @override
  void dispose() {
    command.dispose();
    payload.dispose();
    super.dispose();
  }

  Future<void> send() async {
    setState(() => busy = true);
    try {
      final code = int.parse(command.text.trim(), radix: 16);
      final data = hex
          ? payload.text.trim().isEmpty
                ? <int>[]
                : payload.text
                      .trim()
                      .split(RegExp(r'\s+'))
                      .map((v) => int.parse(v, radix: 16))
                      .toList()
          : ascii.encode(payload.text);
      if (code < 0x20 ||
          code > 0x7f ||
          data.length > 220 ||
          data.any((v) => v < 0 || v > 255)) {
        throw const FormatException('Invalid frame');
      }
      final id =
          'service-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      final result = await widget.bridge.run('rawEcr', id, {
        'command': code,
        'data': data,
      });
      if (mounted) {
        setState(() {
          output.insert(
            0,
            '${DateTime.now()} · TX ${code.toRadixString(16)} · ${data.length} octeți\n${result['outcome']} · ${result['message']}\n$id',
          );
          if (output.length > 100) output.removeLast();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => output.insert(
            0,
            'Eroare: verifică formatul comenzii hex și payload-ul (maximum 220 octeți).',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: CompanionAppBar(title: const Text('Consolă ECR · DEV'), busy: busy),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Activează pentru această sesiune'),
            subtitle: const Text(
              'Comenzi reale, fără confirmări suplimentare. Fără retry automat. Tremol RO.',
            ),
            value: enabled,
            onChanged: busy ? null : (v) => setState(() => enabled = v),
          ),
          TextField(
            controller: command,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'Comandă hex',
              hintText: '20 = status',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: payload,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'Payload',
              hintText: 'Gol pentru status',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Payload hex (octeți separați prin spații)'),
            value: hex,
            onChanged: busy ? null : (v) => setState(() => hex = v),
          ),
          FilledButton(
            onPressed: enabled && !busy ? send : null,
            child: Text(busy ? 'Se execută…' : 'Trimite o singură dată'),
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: output.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(
                  output[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
