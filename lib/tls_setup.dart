import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'tls_provisioning.dart';
import 'connectivity_client.dart';

/// Manual CSR mode never asks the administrator to supply a private key.
class TlsSetup extends StatefulWidget {
  const TlsSetup({super.key, required this.onCompleted});
  final VoidCallback onCompleted;
  @override
  State<TlsSetup> createState() => _TlsSetupState();
}

class _TlsSetupState extends State<TlsSetup> {
  final _host = TextEditingController(), _chain = TextEditingController();
  final _ip = TextEditingController();
  final _proxy = TextEditingController();
  bool _automatic = true;
  String? _interface;
  String? _csr, _message;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _restoreCsr();
    _detectLan();
  }

  Future<void> _detectLan() async {
    try {
      final address = await detectLanAddress();
      if (!mounted || _ip.text.isNotEmpty) return;
      setState(() {
        _ip.text = address.ip;
        _interface = address.name;
      });
      await _configureAutomatically();
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is HttpException ? error.message : '$error',
        );
      }
    }
  }

  Future<void> _restoreCsr() async {
    try {
      final provisioning = await _provisioning();
      final pending = File('${provisioning.directory.path}/pending.json');
      if (!await pending.exists() || !mounted) return;
      final data =
          jsonDecode(await pending.readAsString()) as Map<String, dynamic>;
      if (await const FlutterSecureStorage().read(
                key: 'connectivity_settings_v1',
              ) !=
              null ||
          !mounted) {
        return;
      }
      setState(() {
        _host.text = data['hostname'] as String;
        _csr = data['csr'] as String;
      });
    } catch (_) {
      /* No pending manual CSR to resume. */
    }
  }

  Future<void> _configureAutomatically() => _run(() async {
    final client = ConnectivityClient(provisioning: await _provisioning());
    await client.configure(
      _ip.text,
      interfaceName: _interface,
      onlyIfDue: true,
    );
    if (mounted) widget.onCompleted();
  });

  @override
  void dispose() {
    _host.dispose();
    _chain.dispose();
    _ip.dispose();
    _proxy.dispose();
    super.dispose();
  }

  Future<TlsProvisioning> _provisioning() async {
    final directory = await getApplicationSupportDirectory();
    return TlsProvisioning(Directory('${directory.path}/local-tls'));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is HttpException ? error.message : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_automatic) ...[
        const Text(
          'Securizăm automat conexiunea cu POS-ul. Prima emitere a certificatului poate dura câteva minute.',
        ),
        const SizedBox(height: 16),
        if (_interface != null) Text('Rețea detectată: ${_ip.text}'),
        ExpansionTile(
          title: const Text('Adresă de rețea manuală'),
          initiallyExpanded: _interface == null,
          children: [
            TextField(
              controller: _ip,
              onChanged: (_) => _interface = null,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'IP LAN al acestui Companion',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _configureAutomatically,
          child: Text(_busy ? 'Securizare în curs…' : 'Reîncearcă securizarea'),
        ),
      ],
      ExpansionTile(
        title: const Text('Setări avansate'),
        subtitle: const Text('Doar pentru infrastructură configurată separat'),
        children: [
          SwitchListTile(
            title: const Text('Certificat administrat manual'),
            value: !_automatic,
            onChanged: _busy
                ? null
                : (value) => setState(() => _automatic = !value),
          ),
        ],
      ),
      if (!_automatic) ...[
        const Text(
          'CSR și certificat individual',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const Text(
          'Cheia privată este generată aici și nu părăsește telefonul. Certificatul trebuie emis de o autoritate în care browserul are încredere.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _proxy,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Endpoint reverse proxy HTTPS (opțional)',
            helperText:
                'Proxy-ul trebuie să valideze TLS-ul backend; nu folosi HTTP sau tls_insecure_skip_verify.',
            helperMaxLines: 3,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _host,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Hostname Companion',
            hintText: 'Hostname configurat în DNS',
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final csr = await (await _provisioning()).createCsr(
                    _host.text,
                  );
                  if (mounted) {
                    setState(() {
                      _csr = csr;
                      _message = null;
                    });
                  }
                }),
          icon: const Icon(Icons.key),
          label: const Text('Generează CSR'),
        ),
        if (_csr != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: _csr!)),
            icon: const Icon(Icons.copy),
            label: const Text('Copiază CSR'),
          ),
          ExpansionTile(
            title: const Text('Vezi CSR'),
            children: [
              SelectableText(
                _csr!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final file = await openFile();
                    if (file == null) return;
                    if (await file.length() > 65536) {
                      throw const FormatException(
                        'Fișierul certificatului este prea mare.',
                      );
                    }
                    final chain = await file.readAsString();
                    if (!chain.contains('BEGIN CERTIFICATE') ||
                        chain.contains('PRIVATE KEY')) {
                      throw const FormatException(
                        'Selectează doar certificatul PEM și lanțul, fără cheie privată.',
                      );
                    }
                    _chain.text = chain;
                    _message =
                        'Certificat încărcat. Validează înainte de instalare.';
                  }),
            icon: const Icon(Icons.upload_file),
            label: const Text('Importă certificat PEM'),
          ),
          TextField(
            controller: _chain,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !_busy,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Certificat și lanț intermediar PEM',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await (await _provisioning()).install(
                      _host.text,
                      _chain.text,
                      reverseProxy: _proxy.text.trim().isEmpty
                          ? null
                          : _proxy.text.trim(),
                    );
                    await const FlutterSecureStorage().delete(
                      key: 'connectivity_settings_v1',
                    );
                    await const FlutterSecureStorage().delete(
                      key: 'connectivity_authorization_v1',
                    );
                    if (mounted) widget.onCompleted();
                  }),
            icon: const Icon(Icons.verified_user),
            label: const Text('Validează și instalează'),
          ),
        ],
      ],
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_message!, style: const TextStyle(color: Colors.amber)),
        ),
      if (_busy) const LinearProgressIndicator(),
    ],
  );
}
