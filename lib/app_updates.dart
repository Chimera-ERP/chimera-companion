import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'enrollment.dart';
import 'companion_dialog.dart';
import 'android_settings.dart';

class CompanionRelease {
  CompanionRelease(Map<String, dynamic> json, Uri erp)
    : versionCode = json['versionCode'] as int,
      versionName = json['versionName'] as String,
      size = json['size'] as int,
      digest = json['sha256'] as String,
      url = erp.resolve(json['path'] as String) {
    if (json['version'] != 1 ||
        json['packageName'] != 'ro.tabusociety.chimera_companion' ||
        versionCode < 1 ||
        versionName.length > 80 ||
        size < 1 ||
        size > 250 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        url.scheme != 'https' ||
        url.origin != erp.origin ||
        url.path != '/api/companion-updates/$digest.apk' ||
        url.hasQuery ||
        url.hasFragment ||
        url.userInfo.isNotEmpty) {
      throw const FormatException('Pachet de actualizare invalid.');
    }
  }
  final int versionCode, size;
  final String versionName, digest;
  final Uri url;
}

class CompanionUpdater {
  static const channel = MethodChannel('chimera/updates');
  Future<CompanionRelease?> check({String? erpUrl}) async {
    if (!Platform.isAndroid) return null;
    final saved = await const FlutterSecureStorage().read(
      key: 'erp_pairing_v1',
    );
    if (saved == null && (erpUrl == null || erpUrl.trim().isEmpty)) {
      throw const UpdateServerRequired();
    }
    final erp = erpAddress(
      saved == null ? erpUrl! : jsonDecode(saved)['erp_url'] as String,
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        erp.resolve('/api/companion-updates/manifest'),
      );
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode == 404) {
        throw const HttpException('Nicio versiune publicată.');
      }
      if (response.statusCode != 200) {
        throw const HttpException('Serverul de actualizări este indisponibil.');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        bytes.addAll(chunk);
        if (bytes.length > 16384) {
          throw const FormatException('Manifest prea mare.');
        }
      }
      final release = CompanionRelease(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        erp,
      );
      final current = await channel.invokeMethod<int>('versionCode');
      return release.versionCode > (current ?? 0) ? release : null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> canInstall() async =>
      await channel.invokeMethod<bool>('canInstall') ?? false;

  Future<File> download(CompanionRelease release) async {
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}/updates',
    );
    await directory.create(recursive: true);
    final file = File('${directory.path}/companion.apk.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final sink = file.openWrite();
    try {
      final request = await client.getUrl(release.url);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw const HttpException('Descărcarea a eșuat.');
      }
      var size = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        size += chunk.length;
        if (size > release.size) {
          throw const FormatException('Dimensiune APK incorectă.');
        }
        sink.add(chunk);
      }
      await sink.close();
      if (size != release.size ||
          (await sha256.bind(file.openRead()).first).toString() !=
              release.digest) {
        throw const FormatException(
          'Integritatea APK-ului nu a putut fi verificată.',
        );
      }
      return await file.rename('${directory.path}/companion.apk');
    } finally {
      client.close(force: true);
      await sink.close();
    }
  }
}

class UpdateServerRequired implements Exception {
  const UpdateServerRequired();
}

class CompanionUpdateButton extends StatefulWidget {
  const CompanionUpdateButton({
    super.key,
    required this.isBusy,
    required this.setUpdating,
    this.autoCheck = false,
    this.updater,
  });
  final bool Function() isBusy;
  final void Function(bool) setUpdating;
  final bool autoCheck;
  final CompanionUpdater? updater;
  @override
  State<CompanionUpdateButton> createState() => _CompanionUpdateButtonState();
}

class _CompanionUpdateButtonState extends State<CompanionUpdateButton> {
  late final updater = widget.updater ?? CompanionUpdater();
  CompanionRelease? release;
  Timer? timer;
  bool checking = false;
  @override
  void initState() {
    super.initState();
    if (widget.autoCheck) {
      unawaited(check());
      timer = Timer.periodic(
        const Duration(hours: 1),
        (_) => unawaited(check()),
      );
    }
  }

  Future<void> check() async {
    if (checking) return;
    checking = true;
    try {
      final next = await updater.check();
      if (mounted) setState(() => release = next);
    } catch (_) {
      /* Explicit checks present a retry action. */
    } finally {
      checking = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> open() async {
    if (widget.isBusy()) return;
    widget.setUpdating(true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CompanionUpdateDialog(updater: updater),
      );
    } finally {
      widget.setUpdating(false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Verifică actualizările',
    onPressed: widget.isBusy() ? null : open,
    icon: Badge(
      isLabelVisible: release != null,
      child: const Icon(Icons.system_update),
    ),
  );
}

class CompanionUpdateDialog extends StatefulWidget {
  const CompanionUpdateDialog({super.key, required this.updater});
  final CompanionUpdater updater;
  @override
  State<CompanionUpdateDialog> createState() => _CompanionUpdateDialogState();
}

class _CompanionUpdateDialogState extends State<CompanionUpdateDialog>
    with WidgetsBindingObserver {
  final _server = TextEditingController();
  bool _working = true,
      _needsServer = false,
      _canInstall = false,
      _failed = false;
  String _message = 'Se verifică versiunea…';
  CompanionRelease? _release;
  File? _downloaded;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _server.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_working && _release != null) {
      _permission();
    }
  }

  Future<void> _permission() async {
    try {
      final allowed = await widget.updater.canInstall();
      if (mounted) setState(() => _canInstall = allowed);
    } catch (_) {
      if (mounted) setState(() => _canInstall = false);
    }
  }

  Future<void> _check() async {
    setState(() {
      _working = true;
      _failed = false;
      _message = 'Se verifică versiunea…';
      _release = null;
      _downloaded = null;
    });
    try {
      final next = await widget.updater.check(erpUrl: _server.text.trim());
      if (!mounted) return;
      setState(() {
        _release = next;
        _message = next == null
            ? 'Aplicația este la zi.'
            : 'Versiunea ${next.versionName} este disponibilă.';
      });
      if (next != null) await _permission();
    } on UpdateServerRequired {
      if (mounted) {
        setState(() {
          _needsServer = true;
          _message = 'De unde verificăm actualizările?';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message =
              'Nu pot verifica versiunea. Verifică conexiunea și reîncearcă.';
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _settings() async {
    try {
      await AndroidSettings.open('install');
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = 'Nu pot deschide setările Android.';
        });
      }
    }
  }

  Future<void> _install() async {
    setState(() {
      _working = true;
      _failed = false;
      _message = 'Se descarcă și se verifică…';
    });
    try {
      if (!await widget.updater.canInstall()) {
        if (mounted) {
          setState(() {
            _canInstall = false;
            _message = 'Permite instalarea în setările Android.';
          });
        }
        return;
      }
      _downloaded ??= await widget.updater.download(_release!);
      final started = await CompanionUpdater.channel.invokeMethod<bool>(
        'install',
        {'path': _downloaded!.path, 'versionCode': _release!.versionCode},
      );
      if (mounted) {
        setState(() {
          _canInstall = started == true;
          _message = started == true
              ? 'Confirmă instalarea în Android.'
              : 'Permite instalarea în setările Android.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = 'Actualizarea a eșuat. Reîncearcă.';
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => CompanionDialog(
    title: 'Actualizare Companion',
    busy: _working,
    actions: [
      TextButton(
        onPressed: _working ? null : () => Navigator.pop(context),
        child: const Text('Închide'),
      ),
      if (_release == null)
        FilledButton(
          onPressed: _working ? null : _check,
          child: const Text('Verifică acum'),
        )
      else
        FilledButton(
          onPressed: _working || !_canInstall ? null : _install,
          child: const Text('Instalează'),
        ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_message, style: TextStyle(color: _failed ? Colors.amber : null)),
        if (_working)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(),
          ),
        if (_needsServer)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: TextField(
              key: const ValueKey('update-erp'),
              controller: _server,
              enabled: !_working,
              decoration: const InputDecoration(
                labelText: 'Adresă ERP',
                hintText: 'https://chimera.firma.ro',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
            ),
          ),
        if (_release != null && !_canInstall && !_working) ...[
          const SizedBox(height: 16),
          const Text('Android cere permisiunea de instalare pentru Companion.'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _settings,
                child: const Text('Setări Android'),
              ),
              TextButton(
                onPressed: _permission,
                child: const Text('Reverifică permisiunea'),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}
