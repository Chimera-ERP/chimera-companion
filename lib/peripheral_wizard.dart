import 'package:flutter/material.dart';

/// Shared local peripheral setup. Selecting transport never performs hardware I/O.
class PeripheralWizard extends StatefulWidget {
  const PeripheralWizard({
    super.key,
    required this.transport,
    required this.child,
    required this.summary,
    required this.ready,
    this.validate,
    this.finish,
    this.busy = false,
    this.transports,
    this.onTransport,
  });
  final String transport;
  final List<String>? transports;
  final ValueChanged<String>? onTransport;
  final Widget child, summary;
  final bool ready, busy;
  final bool Function()? validate;
  final VoidCallback? finish;
  @override
  State<PeripheralWizard> createState() => _PeripheralWizardState();
}

class _PeripheralWizardState extends State<PeripheralWizard> {
  int step = 0;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '${step + 1} din 3 · ${['Conexiune', 'Dispozitiv', 'Verificare'][step]}',
      ),
      const SizedBox(height: 20),
      if (step == 0) ...[
        for (final type in ['Bluetooth', 'LAN'])
          ListTile(
            leading: Icon(
              type == 'Bluetooth' ? Icons.bluetooth : Icons.lan_outlined,
            ),
            title: Text(type),
            subtitle: !(widget.transports ?? [widget.transport]).contains(type)
                ? const Text('În curând')
                : null,
            enabled:
                (widget.transports ?? [widget.transport]).contains(type) &&
                !widget.busy,
            trailing: const Icon(Icons.chevron_right),
            onTap:
                (widget.transports ?? [widget.transport]).contains(type) &&
                    !widget.busy
                ? () {
                    widget.onTransport?.call(type);
                    setState(() => step = 1);
                  }
                : null,
          ),
      ],
      // Keep controllers and pending operations alive while reviewing/backtracking.
      Offstage(offstage: step != 1, child: widget.child),
      if (step == 2) widget.summary,
      const SizedBox(height: 24),
      Row(
        children: [
          if (step > 0)
            TextButton(
              onPressed: widget.busy ? null : () => setState(() => step--),
              child: const Text('Înapoi'),
            ),
          const Spacer(),
          if (step == 1)
            FilledButton(
              onPressed: widget.busy || !widget.ready
                  ? null
                  : () {
                      if (widget.validate?.call() ?? true) {
                        setState(() => step = 2);
                      }
                    },
              child: const Text('Continuă'),
            ),
          if (step == 2 && widget.finish != null)
            FilledButton(
              onPressed: widget.busy || !widget.ready ? null : widget.finish,
              child: Text(widget.busy ? 'Se salvează…' : 'Salvează'),
            ),
        ],
      ),
    ],
  );
}
