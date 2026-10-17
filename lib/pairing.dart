import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'debug_panel.dart';
import 'enrollment.dart';
import 'device_credentials.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'setup_header.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    this.embedded = false,
    this.onCompleted,
    this.action,
  });
  final bool embedded;
  final Future<void> Function()? onCompleted;
  final ValueNotifier<SetupAction?>? action;
  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _url = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;
  bool _paired = false;
  bool _error = false;
  void _syncAction() => widget.action?.value = SetupAction(
    _busy
        ? 'Se asociază…'
        : _paired
        ? 'Continuă'
        : 'Asociază',
    _busy
        ? null
        : _paired
        ? _continue
        : _pair,
    busy: _busy,
  );
  Future<void> _continue() async {
    if (widget.onCompleted != null) {
      await widget.onCompleted!();
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  String? _notice;
  set _message(String? value) {
    _notice = value;
    if (value != null) {
      debugLog(value);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncAction();
    });
    _restore();
  }

  Future<void> _restore() async {
    try {
      final saved = await const FlutterSecureStorage().read(
        key: 'erp_pairing_v1',
      );
      if (saved == null || !mounted) return;
      final data = jsonDecode(saved) as Map<String, dynamic>;
      _url.text = (data['erp_url'] as String).replaceFirst(
        RegExp(r'^https://'),
        '',
      );
      _paired = true;
      setState(
        () => _message =
            'Asociere salvată: ${data['location_name'] ?? data['location_id']}.',
      );
    } catch (_) {
      if (mounted) setState(() => _message = 'Nu pot citi asocierea salvată.');
    } finally {
      if (mounted) _syncAction();
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    _error = true;
    Uri uri;
    try {
      uri = erpAddress(_url.text);
    } on FormatException {
      setState(() => _message = 'Introdu adresa ERP și PIN-ul de 6 cifre.');
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(_pin.text.trim())) {
      setState(
        () => _message = 'Introdu adresa HTTPS a ERP și PIN-ul de 6 cifre.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    _syncAction();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(enrollmentEndpoint(uri));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(await enrollmentProof(uri, _pin.text.trim())));
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 15));
      final data = parseEnrollmentResponse(response.statusCode, body);
      await const FlutterSecureStorage().write(
        key: 'erp_pairing_v1',
        value: jsonEncode({...data, 'erp_url': uri.origin}),
      );
      await const FlutterSecureStorage().delete(key: 'enrollment_attempt_v1');
      _pin.clear();
      _paired = true;
      _error = false;
      if (mounted) {
        setState(
          () => _message =
              'Asociat cu ${data['location_name'] ?? data['location_id']}.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is FormatException
              ? error.message
              : 'Conexiunea sau salvarea a eșuat. Verifică ERP-ul și conexiunea.',
        );
      }
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _busy = false);
      if (mounted) _syncAction();
    }
  }

  @override
  Widget build(BuildContext context) => widget.embedded
      ? _body()
      : DebugScaffold(title: 'Asociere cu ERP', body: _body(), busy: _busy);

  Widget _body() => ListView(
    shrinkWrap: widget.embedded,
    physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
    padding: widget.embedded ? EdgeInsets.zero : const EdgeInsets.all(16),
    children: [
      if (!widget.embedded)
        const Text(
          'Conectează Chimera',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      if (!widget.embedded) const SizedBox(height: 16),
      const Text(
        'PIN-ul se generează în Chimera → Dispozitive → Companion-uri.',
      ),
      const SizedBox(height: 20),
      if (_paired) ...[
        const Icon(
          Icons.check_circle_outline,
          size: 32,
          color: Color(0xff79dbc3),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  setState(() {
                    _paired = false;
                    _notice = null;
                  });
                  _syncAction();
                },
          child: const Text('Schimbă asocierea'),
        ),
      ],
      if (!_paired) ...[
        TextField(
          controller: _url,
          enabled: !_busy,
          onChanged: (value) {
            if (value.startsWith('https://')) {
              final host = value.substring(8);
              _url.value = TextEditingValue(
                text: host,
                selection: TextSelection.collapsed(offset: host.length),
              );
            }
          },
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Adresa ERP',
            prefixText: 'https://',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            hintText: 'chimera.firma.ro',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _pin,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(labelText: 'PIN generat în ERP'),
        ),
      ],
      if (_notice != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            _notice!,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: _error ? Colors.amber : const Color(0xff79dbc3),
            ),
          ),
        ),
      if (widget.action == null && !_paired)
        FilledButton(
          onPressed: _busy ? null : _pair,
          child: Text(_busy ? 'Se asociază…' : 'Asociază'),
        ),
      if (widget.action == null && _paired)
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  if (widget.onCompleted != null) {
                    await widget.onCompleted!();
                  } else if (mounted) {
                    Navigator.pop(context);
                  }
                },
          icon: const Icon(Icons.check),
          label: Text(widget.embedded ? 'Continuă la HTTPS' : 'Închide'),
        ),
    ],
  );
}
