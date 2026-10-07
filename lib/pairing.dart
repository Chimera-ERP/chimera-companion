import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'debug_panel.dart';
import 'enrollment.dart';
import 'device_credentials.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({super.key, this.embedded = false, this.onCompleted});
  final bool embedded;
  final Future<void> Function()? onCompleted;
  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _url = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;
  bool _paired = false;
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
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
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
    }
  }

  @override
  Widget build(BuildContext context) => widget.embedded
      ? _body()
      : DebugScaffold(title: 'Asociere cu ERP', body: _body());

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
        'Generează PIN-ul în Chimera → Dispozitive → Companion-uri. Nu este necesar QR sau cont de operator.',
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _url,
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
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: const InputDecoration(labelText: 'PIN generat în ERP'),
      ),
      if (_notice != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            _notice!,
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xff79dbc3),
            ),
          ),
        ),
      FilledButton(
        onPressed: _busy ? null : _pair,
        child: Text(_busy ? 'Se asociază…' : 'Asociază'),
      ),
      if (_paired)
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
