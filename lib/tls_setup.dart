import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'tls_provisioning.dart';
import 'connectivity_client.dart';
import 'setup_header.dart';
import 'companion_dialog.dart';
import 'android_settings.dart';
import 'companion_scene.dart';
import 'companion_help.dart';

/// Manual CSR mode never asks the administrator to supply a private key.
class TlsSetup extends StatefulWidget {
  const TlsSetup({
    super.key,
    required this.onCompleted,
    this.action,
    this.showScene = true,
    this.detectAddress = detectLanAddress,
    this.configureConnection,
  });
  final Future<({String name, String ip})> Function() detectAddress;
  final Future<void> Function(String ip, String? interfaceName)?
  configureConnection;
  final VoidCallback onCompleted;
  final ValueNotifier<SetupAction?>? action;
  final bool showScene;
  @override
  State<TlsSetup> createState() => _TlsSetupState();
}

class _TlsSetupState extends State<TlsSetup> with WidgetsBindingObserver {
  VoidCallback? _dialogUpdate;
  void _change(VoidCallback action) {
    if (!mounted) return;
    setState(action);
    _dialogUpdate?.call();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy && _automatic) {
      _detectLan();
    }
  }

  final _host = TextEditingController(), _chain = TextEditingController();
  final _ip = TextEditingController();
  final _proxy = TextEditingController();
  bool _automatic = true;
  String? _interface;
  String? _csr, _message;
  bool _busy = false;
  bool _completed = false;
  bool _detecting = true;
  CompanionSceneState get _scene => _completed
      ? CompanionSceneState.ready
      : _message != null
      ? CompanionSceneState.attention
      : CompanionSceneState.connecting;
  void _syncAction() => widget.action?.value = SetupAction(
    _busy
        ? 'Securizare în curs…'
        : _automatic
        ? 'Reîncearcă'
        : 'Configurare avansată',
    _busy
        ? null
        : _automatic
        ? _detectLan
        : _advanced,
    busy: _busy,
    scene: _scene,
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _detectLan();
    });
    _restoreCsr();
  }

  Future<void> _detectLan() => _run(() async {
    _change(() => _detecting = true);
    final address = await widget.detectAddress();
    if (!mounted) return;
    _change(() {
      _ip.text = address.ip;
      _interface = address.name;
      _detecting = false;
    });
    if (_automatic) await _configure();
  });

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
      _change(() {
        _host.text = data['hostname'] as String;
        _csr = data['csr'] as String;
      });
    } catch (_) {
      /* No pending manual CSR to resume. */
    }
  }

  Future<void> _configureAutomatically() => _run(_configure);

  Future<void> _configure() async {
    _change(() => _detecting = false);
    if (widget.configureConnection != null) {
      await widget.configureConnection!(_ip.text, _interface);
    } else {
      final client = ConnectivityClient(provisioning: await _provisioning());
      await client.configure(
        _ip.text,
        interfaceName: _interface,
        onlyIfDue: true,
      );
    }
    if (mounted) {
      if (_dialogUpdate != null) Navigator.of(context).pop();
      _completed = true;
      widget.onCompleted();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    if (_busy || _completed) return;
    _change(() {
      _busy = true;
      _message = null;
    });
    _syncAction();
    try {
      await action();
    } catch (error) {
      if (mounted) {
        _change(
          () => _message = error is HttpException ? error.message : '$error',
        );
      }
    } finally {
      if (mounted) {
        _change(() => _busy = false);
        if (!_completed) _syncAction();
      }
    }
  }

  Future<void> _settings() async {
    try {
      await AndroidSettings.open('wifi');
    } catch (_) {
      if (mounted) _change(() => _message = 'Nu pot deschide setările Wi-Fi.');
    }
  }

  Future<void> _advanced() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          _dialogUpdate = () {
            if (context.mounted) update(() {});
          };
          return CompanionDialog(
            title: 'Rețea · setări avansate',
            busy: _busy,
            actions: [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('Închide'),
              ),
              if (_automatic)
                FilledButton(
                  onPressed: _busy ? null : _configureAutomatically,
                  child: const Text('Securizează conexiunea'),
                ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _settings,
                      icon: const Icon(Icons.wifi, size: 18),
                      label: const Text('Setări Wi-Fi'),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _detectLan,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Reverifică rețeaua'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _ip,
                  enabled: !_busy,
                  onChanged: (_) => _interface = null,
                  decoration: const InputDecoration(
                    labelText: 'IP LAN al Companion-ului',
                    suffixIcon: CompanionHelpButton(
                      title: 'Adresa din rețeaua locației',
                      message:
                          'Adresa este detectată automat. Modific-o doar dacă acest dispozitiv folosește o altă interfață de rețea.',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Certificat administrat manual'),
                  value: !_automatic,
                  onChanged: _busy
                      ? null
                      : (v) {
                          _change(() => _automatic = !v);
                          _syncAction();
                        },
                ),
                if (!_automatic) ...[
                  const Row(
                    children: [
                      Expanded(
                        child: Text(
                          'CSR și certificat individual',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      CompanionHelpButton(
                        title: 'Despre certificatul manual',
                        message:
                            'Cheia privată este generată aici și nu părăsește telefonul. Certificatul trebuie emis de o autoritate în care browserul are încredere.',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _proxy,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Reverse proxy HTTPS',
                      suffixIcon: CompanionHelpButton(
                        title: 'Despre reverse proxy',
                        message:
                            'Opțional. Proxy-ul trebuie să valideze TLS-ul backend; nu folosi HTTP sau tls_insecure_skip_verify.',
                      ),
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
                      hintText: 'companion.exemplu.ro',
                      suffixIcon: CompanionHelpButton(
                        title: 'Despre hostname',
                        message:
                            'Folosește numele configurat în DNS pentru acest Companion. Certificatul trebuie să fie emis pentru același nume.',
                      ),
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
                              _change(() {
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
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: _csr!)),
                      icon: const Icon(Icons.copy),
                      label: const Text('Copiază CSR'),
                    ),
                    ExpansionTile(
                      title: const Text('Vezi CSR'),
                      children: [
                        SelectableText(
                          _csr!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
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
                              if (mounted && context.mounted) {
                                Navigator.of(context).pop();
                                _completed = true;
                                widget.onCompleted();
                              }
                            }),
                      icon: const Icon(Icons.verified_user),
                      label: const Text('Validează și instalează'),
                    ),
                  ],
                ],

                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_message!),
                  ),
              ],
            ),
          );
        },
      ),
    );
    _dialogUpdate = null;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.showScene) ...[
        CompanionScene(scene: _scene),
        const SizedBox(height: 24),
      ],
      Text(
        _completed
            ? 'Conexiunea este pregătită'
            : _message != null
            ? 'Conexiunea are nevoie de atenție'
            : !_automatic
            ? 'Configurare manuală'
            : _detecting
            ? 'Găsim rețeaua locației'
            : 'Pregătim conexiunea sigură',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      Semantics(
        liveRegion: true,
        child: Text(
          _message != null
              ? 'Verifică accesul la internet și conectarea la rețeaua locației, apoi reîncearcă.'
              : !_automatic
              ? 'Continuă din setările avansate.'
              : 'Companion se ocupă de configurare. Durează câteva momente.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      const SizedBox(height: 24),
      Center(
        child: TextButton.icon(
          onPressed: _busy ? null : _advanced,
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Avansat'),
        ),
      ),
      if (widget.action == null && !_completed)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: FilledButton(
            onPressed: _busy
                ? null
                : _automatic
                ? _detectLan
                : _advanced,
            child: Text(_busy ? 'Se configurează…' : 'Reîncearcă'),
          ),
        ),
    ],
  );
}
