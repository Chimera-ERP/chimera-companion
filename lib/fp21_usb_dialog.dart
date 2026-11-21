import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'companion_dialog.dart';
import 'hardware/contracts.dart';
import 'hardware/fp21_usb.dart';
import 'hardware/tremol_adapter.dart';

Future<void> showFp21UsbDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const Fp21UsbDialog());

class Fp21UsbDialog extends StatefulWidget {
  const Fp21UsbDialog({super.key, this.usb = const Fp21Usb()});

  final Fp21Usb usb;

  @override
  State<Fp21UsbDialog> createState() => _Fp21UsbDialogState();
}

enum _UsbAction {
  printTest('Se tipărește bonul nefiscal de test…'),
  finishTest('Se continuă bonul nefiscal de test…'),
  close('Se închide bonul nefiscal…'),
  qr('Se testează codul QR…'),
  cut('Se taie hârtia…');

  const _UsbAction(this.progress);
  final String progress;
  bool get direct => this == close || this == cut || this == qr;
}

class _Fp21UsbDialogState extends State<Fp21UsbDialog> {
  final _statusFocus = FocusNode(skipTraversal: true);
  final _operator = TextEditingController(text: '1');
  final _password = TextEditingController();
  List<Fp21UsbDevice> _devices = [];
  String? _selectedId;
  bool _loading = false;
  bool _reading = false;
  _UsbAction? _pendingAction;
  bool get _printing => _pendingAction != null;
  bool _paperMatches = false;
  String? _error;
  DeviceStatus? _status;
  HardwareResult? _result;
  bool _directResult = false;

  int? get _operatorNumber => int.tryParse(_operator.text);
  bool get _validOperator =>
      (_operatorNumber ?? 0) >= 1 && (_operatorNumber ?? 0) <= 20;
  bool get _validPassword =>
      RegExp(r'^[\x20-\x3a\x3c-\x7e]{4}$').hasMatch(_password.text);

  String? get _interruptedTestId {
    final value = _status?.details['interruptedTestId'];
    return _status?.ready == false && value is String && value.isNotEmpty
        ? value
        : null;
  }

  bool get _busy => _loading || _reading || _printing;
  bool get _checkPaper =>
      !_directResult && _result?.outcome == CommandOutcome.unknown;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  @override
  void dispose() {
    _statusFocus.dispose();
    _operator.dispose();
    _password.dispose();
    super.dispose();
  }

  void _clearProbe() {
    _status = null;
    _paperMatches = false;
    _error = null;
    _result = null;
    _directResult = false;
    _password.clear();
  }

  Future<void> _discover() async {
    if (_busy) return;
    setState(() {
      _loading = true;
      _clearProbe();
    });
    try {
      final devices = await widget.usb.devices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        if (!devices.any((device) => device.id == _selectedId)) {
          _selectedId = devices.length == 1 ? devices.single.id : null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _devices = [];
        _selectedId = null;
        _error =
            'Dispozitivele USB nu au putut fi căutate. Verifică legătura și caută din nou.';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _probe() async {
    final id = _selectedId;
    if (_busy || _checkPaper || id == null) return;
    setState(() {
      _reading = true;
      _clearProbe();
    });
    try {
      final status = await widget.usb.probe(id);
      if (mounted && _selectedId == id) setState(() => _status = status);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _probeError(error));
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _printTest() async {
    final id = _selectedId;
    if (_busy || id == null || _status?.ready != true) return;
    if (!_validOperator || !_validPassword) return;
    final operator = _operatorNumber!;
    final password = _password.text;
    final commandId = _commandId('test');
    await _sendDocumentAction(
      _UsbAction.printTest,
      () => widget.usb.printTest(
        id,
        operatorNumber: operator,
        operatorPassword: password,
        commandId: commandId,
      ),
    );
  }

  Future<void> _finishInterruptedTest() async {
    final id = _selectedId;
    final originalId = _interruptedTestId;
    if (_busy || id == null || originalId == null || !_paperMatches) return;
    await _sendDocumentAction(
      _UsbAction.finishTest,
      () => widget.usb.finishInterruptedTest(id, originalId),
    );
  }

  String _commandId(String operation) =>
      'usb-$operation-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

  Future<void> _forceClose() async {
    final id = _selectedId;
    if (_busy || id == null) return;
    await _sendDocumentAction(
      _UsbAction.close,
      () => widget.usb.forceCloseNonFiscal(id, _commandId('close')),
    );
  }

  Future<void> _printQr() async {
    final id = _selectedId;
    if (_busy || id == null || _status?.ready != true) return;
    await _sendDocumentAction(
      _UsbAction.qr,
      () => widget.usb.printQrTest(id, _commandId('qr')),
    );
  }

  Future<void> _cutPaper() async {
    final id = _selectedId;
    if (_busy || id == null) return;
    await _sendDocumentAction(
      _UsbAction.cut,
      () => widget.usb.cutPaper(id, _commandId('cut')),
    );
  }

  Future<void> _sendDocumentAction(
    _UsbAction action,
    Future<HardwareResult> Function() send,
  ) async {
    _statusFocus.requestFocus();
    setState(() {
      _pendingAction = action;
      _paperMatches = false;
      _password.clear();
    });
    HardwareResult result;
    try {
      result = await send();
    } catch (_) {
      result = HardwareResult(
        CommandOutcome.unknown,
        message: switch (action) {
          _UsbAction.close => 'Imprimanta nu a confirmat închiderea bonului.',
          _UsbAction.cut => 'Imprimanta nu a confirmat tăierea hârtiei.',
          _ => 'Imprimanta nu a confirmat tipărirea.',
        },
      );
    }
    if (!mounted) return;
    setState(() {
      _pendingAction = null;
      _clearProbe();
      _result = result;
      _directResult = action.direct;
    });
  }

  String _probeError(Object error) {
    if (error is TimeoutException) {
      return 'Imprimanta nu a răspuns la timp. Verifică alimentarea și cablul USB.';
    }
    if (error is FormatException) {
      return 'Răspunsul USB nu este un status FP21 valid. Verifică dispozitivul selectat.';
    }
    if (error is Fp21UsbTransferFailure && error.message?.isNotEmpty == true) {
      return error.message!;
    }
    if (error is PlatformException && error.message?.isNotEmpty == true) {
      return error.message!;
    }
    if (error is TremolPaperRequired) return error.toString();
    if (error is StateError) return error.message;
    return 'Citirea stării a eșuat. Verifică legătura USB și caută din nou.';
  }

  String get _feedback {
    if (_loading) return 'Se caută imprimanta pe USB…';
    if (_reading) return 'Se citește starea imprimantei…';
    if (_pendingAction != null) return _pendingAction!.progress;
    if (_error != null) return _error!;
    if (_checkPaper) {
      return '${_result!.message} Verifică dacă bonul a ieșit complet înainte de un alt test.';
    }
    if (_directResult && _result?.outcome == CommandOutcome.unknown) {
      return '${_result!.message} Verifică hârtia și citește din nou starea imprimantei.';
    }
    if (_result != null) return _result!.message;
    if (_status != null) {
      return 'Imprimanta a răspuns prin USB. ${_status!.description}';
    }
    if (_devices.isEmpty) {
      return 'Nicio imprimantă USB găsită. Conectează FP21 la terminal și pornește-o.';
    }
    return 'La prima comandă, Android poate cere acces la USB.';
  }

  @override
  Widget build(BuildContext context) {
    final ready = _status?.ready == true;
    return CompanionDialog(
      title: 'Activa FP21 · USB',
      busy: _printing,
      actions: [
        TextButton(
          onPressed: _printing ? null : () => Navigator.of(context).pop(),
          child: const Text('Închide'),
        ),
        if (_checkPaper)
          FilledButton(
            onPressed: _busy ? null : () => setState(() => _result = null),
            child: const Text('Am verificat hârtia'),
          )
        else if (_interruptedTestId != null)
          FilledButton(
            onPressed: _busy || !_paperMatches ? null : _finishInterruptedTest,
            child: const Text('Continuă bonul de test'),
          )
        else if (ready)
          FilledButton(
            onPressed: _printing || !_validOperator || !_validPassword
                ? null
                : _printTest,
            child: const Text('Tipărește bonul de test'),
          )
        else if (_devices.isNotEmpty)
          FilledButton(
            onPressed: _busy || _selectedId == null ? null : _probe,
            child: const Text('Citește starea'),
          )
        else
          TextButton(
            onPressed: _busy ? null : _discover,
            child: const Text('Caută din nou'),
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_devices.length == 1 && !_loading)
            Text(_devices.single.label)
          else if (_devices.isNotEmpty && !_loading)
            DropdownButtonFormField<String>(
              key: ValueKey(_devices.map((d) => d.id).join('|')),
              initialValue: _selectedId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Dispozitiv USB'),
              items: [
                for (final device in _devices)
                  DropdownMenuItem(
                    value: device.id,
                    child: Text(device.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (id) => setState(() {
                      _selectedId = id;
                      _clearProbe();
                    }),
            ),
          if (_devices.isNotEmpty && !_loading && !_printing)
            TextButton(
              onPressed: _busy ? null : _discover,
              child: const Text('Caută din nou'),
            ),
          if (_devices.isNotEmpty && !_loading) const SizedBox(height: 8),
          Focus(
            focusNode: _statusFocus,
            child: Semantics(liveRegion: true, child: Text(_feedback)),
          ),
          if (_selectedId != null && !_loading) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (ready)
                  OutlinedButton(
                    onPressed: _busy ? null : _printQr,
                    child: const Text('Testează doar QR'),
                  ),
                OutlinedButton(
                  onPressed: _busy ? null : _forceClose,
                  child: const Text('Închide forțat bonul'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _cutPaper,
                  child: const Text('Taie hârtia'),
                ),
              ],
            ),
          ],
          if (_interruptedTestId != null && !_printing)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _paperMatches,
              title: const Text('Am verificat bonul pe hârtie'),
              subtitle: const Text(
                'Ultima linie este „Cod de bare demonstrativ”. '
                'Lipsesc barele și codul QR.',
              ),
              onChanged: (value) =>
                  setState(() => _paperMatches = value == true),
            ),
          if (ready && !_printing) ...[
            const SizedBox(height: 12),
            const Text(
              'Bon nefiscal cu produse de probă, EAN-13 și QR pentru https://chimeraerp.ro.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _operator,
              decoration: InputDecoration(
                labelText: 'Număr operator (1–20)',
                errorText: _operator.text.isNotEmpty && !_validOperator
                    ? 'Introdu un număr între 1 și 20.'
                    : null,
              ),
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Parolă operator (4 caractere)',
                errorText: _password.text.length >= 4 && !_validPassword
                    ? 'Verifică parola operatorului FP21.'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ],
      ),
    );
  }
}
