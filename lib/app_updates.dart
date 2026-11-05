import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'companion_dialog.dart';
import 'android_settings.dart';
import 'update_release.dart';

export 'update_release.dart' show CompanionRelease;

class CompanionUpdater {
  static const channel = MethodChannel('chimera/updates');
  Future<CompanionRelease?> check() async {
    if (!Platform.isAndroid) return null;
    final current = await channel.invokeMethod<int>('versionCode');
    final client = GitHubReleaseClient();
    try {
      return await client.check(current ?? 0);
    } finally {
      client.close();
    }
  }

  Future<bool> canInstall() async =>
      await channel.invokeMethod<bool>('canInstall') ?? false;

  Future<File> download(CompanionRelease release) async {
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}/updates',
    );
    final client = GitHubReleaseClient();
    try {
      return await client.download(release, directory);
    } finally {
      client.close();
    }
  }
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
  bool _working = true, _canInstall = false, _failed = false;
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
      final next = await widget.updater.check();
      if (!mounted) return;
      setState(() {
        _release = next;
        _message = next == null
            ? 'Aplicația este la zi.'
            : 'Versiunea ${next.versionName} este disponibilă.';
      });
      if (next != null) await _permission();
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
