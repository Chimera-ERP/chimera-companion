import 'package:flutter/material.dart';

import 'android_settings.dart';
import 'companion_dialog.dart';
import 'hardware/tremol_adapter.dart';

class Fp21BluetoothDialog extends StatefulWidget {
  const Fp21BluetoothDialog({
    super.key,
    required this.readState,
    required this.enable,
  });

  final Future<Fp21BluetoothState> Function() readState;
  final Future<Fp21BluetoothState> Function() enable;

  @override
  State<Fp21BluetoothDialog> createState() => _Fp21BluetoothDialogState();
}

class _Fp21BluetoothDialogState extends State<Fp21BluetoothDialog> {
  Fp21BluetoothState? _state;
  bool _busy = false;
  bool _enabling = false;
  bool _settingsFailed = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check({bool enable = false}) async {
    if (_busy || (enable && _state != Fp21BluetoothState.disabled)) return;
    setState(() {
      _busy = true;
      _enabling = enable;
      _settingsFailed = false;
    });
    var state = Fp21BluetoothState.unconfirmed;
    try {
      state = await (enable ? widget.enable() : widget.readState());
    } catch (_) {
      // A missing USB reply cannot establish whether the register changed.
    }
    if (!mounted) return;
    setState(() {
      _state = state;
      _busy = false;
    });
  }

  Future<void> _openPairing() async {
    if (_busy || _state != Fp21BluetoothState.enabled) return;
    setState(() => _settingsFailed = false);
    try {
      await AndroidSettings.open('bluetooth');
    } catch (_) {
      if (mounted) setState(() => _settingsFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = _busy
        ? (_enabling
              ? 'Se activează Bluetooth pe casă…'
              : 'Se citește starea modulului prin USB…')
        : switch (_state) {
            Fp21BluetoothState.enabled =>
              'Bluetooth este activ. În setările Android, alege seria FP21 și confirmă asocierea pe terminal și pe imprimantă.',
            Fp21BluetoothState.disabled => 'Bluetooth este dezactivat pe casă.',
            Fp21BluetoothState.moduleAbsent =>
              'Casa nu raportează un modul Bluetooth instalat.',
            Fp21BluetoothState.unsupportedFirmware =>
              'Această versiune de firmware nu permite configurarea Bluetooth prin Companion.',
            Fp21BluetoothState.unconfirmed || null =>
              'Starea modulului nu a putut fi confirmată. Verifică legătura USB și citește starea din nou.',
          };

    return CompanionDialog(
      title: 'Bluetooth pe Activa FP21',
      busy: _busy,
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Închide'),
        ),
        if (!_busy && _state == Fp21BluetoothState.unconfirmed)
          OutlinedButton.icon(
            onPressed: _check,
            icon: const Icon(Icons.refresh),
            label: const Text('Verifică din nou'),
          ),
        if (!_busy && _state == Fp21BluetoothState.disabled)
          FilledButton(
            onPressed: () => _check(enable: true),
            child: const Text('Activează Bluetooth'),
          ),
        if (!_busy && _state == Fp21BluetoothState.enabled)
          FilledButton(
            onPressed: _openPairing,
            child: const Text('Setări Bluetooth Android'),
          ),
      ],
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            Text(message),
            if (_settingsFailed)
              const Text('Deschide Setări → Bluetooth din meniul Android.'),
          ],
        ),
      ),
    );
  }
}
