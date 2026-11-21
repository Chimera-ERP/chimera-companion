import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'android_settings.dart';
import 'companion_dialog.dart';
import 'hardware/connection.dart';
import 'hardware/fiscal_serial.dart';

class FiscalSerialPicker extends StatefulWidget {
  const FiscalSerialPicker({
    super.key,
    required this.transport,
    required this.model,
    required this.baudRate,
    required this.legacyDatecs,
  });
  final String transport;
  final FiscalModel model;
  final int baudRate;
  final bool legacyDatecs;

  @override
  State<FiscalSerialPicker> createState() => _FiscalSerialPickerState();
}

class _FiscalSerialPickerState extends State<FiscalSerialPicker> {
  List<FiscalSerialDevice> _devices = const [];
  bool _loading = true;
  String? _selecting;
  String? _error;
  bool _permissionDenied = false;

  bool get _bluetooth => widget.transport == 'bluetooth';
  bool get _busy => _loading || _selecting != null;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _failed(Object error) {
    if (!mounted) return;
    setState(() {
      _error = error is PlatformException
          ? error.message ?? error.code
          : error.toString();
      _permissionDenied =
          error is PlatformException && error.code == 'nearby_permission';
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _devices = const [];
      _error = null;
      _permissionDenied = false;
    });
    try {
      final devices = await FiscalSerial.devices(widget.transport);
      if (mounted) setState(() => _devices = devices);
    } catch (error) {
      _failed(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _choose(FiscalSerialDevice device) async {
    if (_busy) return;
    setState(() {
      _selecting = device.id;
      _error = null;
    });
    try {
      final id = await FiscalSerial.select(
        widget.transport,
        device.id,
        model: widget.model,
        baudRate: widget.baudRate,
        legacyDatecs: widget.legacyDatecs,
      );
      if (mounted) {
        Navigator.pop<FiscalSerialDevice>(context, (
          id: id,
          label: device.label,
        ));
      }
    } catch (error) {
      _failed(error);
    } finally {
      if (mounted) setState(() => _selecting = null);
    }
  }

  Future<void> _openSettings(String page) async {
    try {
      await AndroidSettings.open(page);
    } catch (error) {
      _failed(error);
    }
  }

  @override
  Widget build(BuildContext context) => CompanionDialog(
    title: _bluetooth ? 'Case Bluetooth asociate' : 'Case conectate prin USB',
    actions: [
      TextButton(
        onPressed: _selecting != null ? null : () => Navigator.pop(context),
        child: const Text('Anulează'),
      ),
      TextButton.icon(
        onPressed: _busy ? null : _refresh,
        icon: const Icon(Icons.refresh),
        label: const Text('Actualizează'),
      ),
    ],
    busy: _selecting != null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_loading) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          const Text('Se încarcă dispozitivele…'),
        ] else if (_devices.isEmpty && _error == null)
          Text(
            _bluetooth
                ? 'Asociază casa în setările Bluetooth ale Android, apoi actualizează lista.'
                : 'Conectează casa la portul USB al terminalului, pornește-o și actualizează lista.',
          ),
        for (final device in _devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_bluetooth ? Icons.bluetooth : Icons.usb),
            title: Text(device.label),
            subtitle: Text(device.id),
            trailing: _selecting == device.id
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _busy ? null : () => _choose(device),
          ),
        if (_error != null)
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_bluetooth)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy
                  ? null
                  : () =>
                        _openSettings(_permissionDenied ? 'app' : 'bluetooth'),
              icon: const Icon(Icons.settings_outlined),
              label: Text(
                _permissionDenied ? 'Permisiuni aplicație' : 'Setări Bluetooth',
              ),
            ),
          ),
      ],
    ),
  );
}
