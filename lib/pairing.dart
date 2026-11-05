import 'package:flutter/material.dart';
import 'debug_panel.dart';
import 'enrollment.dart';
import 'enrollment_service.dart';
import 'companion_dialog.dart';
import 'package:flutter/services.dart';
import 'setup_header.dart';
import 'companion_scene.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    this.embedded = false,
    this.onCompleted,
    this.action,
    this.showScene = true,
    this.service = const SecureEnrollmentService(),
  });
  final EnrollmentService service;
  final bool embedded;
  final Future<void> Function()? onCompleted;
  final ValueNotifier<SetupAction?>? action;
  final bool showScene;
  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _url = TextEditingController(text: defaultEnrollmentOrigin);
  final _pin = TextEditingController();
  bool _busy = true;
  bool _enterprise = false;
  int _rejectedPins = 0;
  bool _paired = false;
  bool _error = false;
  CompanionSceneState get _scene => _paired
      ? CompanionSceneState.ready
      : _busy
      ? CompanionSceneState.connecting
      : _error && _notice != null
      ? CompanionSceneState.attention
      : CompanionSceneState.welcome;
  void _syncAction() => widget.action?.value = SetupAction(
    _busy
        ? 'Se conectează…'
        : _paired
        ? 'Continuă'
        : 'Conectează',
    _busy
        ? null
        : _paired
        ? _continue
        : _pair,
    busy: _busy,
    scene: _scene,
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
      final data = await widget.service.restore();
      if (data == null || !mounted) return;
      final erp = Uri.parse(data['erp_url'] as String);
      _enterprise =
          enrolledAuthAddress(data, erp).origin != defaultEnrollmentOrigin;
      _url.text = _enterprise ? erp.origin : defaultEnrollmentOrigin;
      _paired = true;
      setState(
        () => _message =
            'Asociere salvată: ${data['location_name'] ?? data['location_id']}.',
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _message = 'Nu pot citi asocierea salvată.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _syncAction();
      }
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    if (_busy || _paired) return;
    _error = true;
    Uri uri;
    try {
      uri = erpAddress(_enterprise ? _url.text : defaultEnrollmentOrigin);
    } on FormatException {
      setState(() => _message = 'Introdu adresa HTTPS a serverului.');
      _syncAction();
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(_pin.text.trim())) {
      setState(() => _message = 'Introdu PIN-ul de 6 cifre.');
      _syncAction();
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    _syncAction();
    try {
      final data = await widget.service.enroll(uri, _pin.text.trim());
      if (!mounted) return;
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
      if (error is EnrollmentRejected &&
          error.status == 400 &&
          uri.origin == defaultEnrollmentOrigin) {
        _rejectedPins++;
      }
      if (mounted) {
        setState(
          () => _message = error is FormatException
              ? error.message
              : 'Conexiunea sau salvarea a eșuat. Verifică ERP-ul și conexiunea.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      if (mounted) _syncAction();
    }
  }

  void _showEnterprise() {
    setState(() {
      _enterprise = true;
      _pin.clear();
      _notice = null;
    });
    _syncAction();
  }

  Future<void> _help() => showDialog<void>(
    context: context,
    builder: (context) => CompanionDialog(
      title: 'Unde găsesc PIN-ul?',
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Am înțeles'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'În Chimera, deschide Administrare → Dispozitive → Companion-uri.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Apasă „Înrolează Companion”, alege locația și generează PIN-ul. Ai nevoie de dreptul de administrare a dispozitivelor.',
          ),
          const SizedBox(height: 20),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _showEnterprise();
            },
            icon: const Icon(Icons.business_outlined),
            label: const Text('Ești client Enterprise sau self-hosted?'),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: widget.embedded
        ? _body()
        : DebugScaffold(
            title: 'Conectare la Chimera',
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: _body(),
              ),
            ),
            busy: _busy,
          ),
  );

  Widget _body() => ListView(
    shrinkWrap: widget.embedded,
    physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
    padding: widget.embedded ? EdgeInsets.zero : const EdgeInsets.all(24),
    children: [
      if (widget.showScene) ...[
        CompanionScene(scene: _scene),
        const SizedBox(height: 24),
      ],
      if (_paired) ...[
        const Icon(
          Icons.check_circle_outline,
          size: 40,
          color: Color(0xff60a5fa),
        ),
        const SizedBox(height: 16),
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
      ] else ...[
        Row(
          children: [
            const Expanded(child: Text('PIN de conectare')),
            IconButton(
              tooltip: 'Unde găsesc PIN-ul?',
              onPressed: _busy ? null : _help,
              icon: const Icon(Icons.info_outline, size: 20),
            ),
          ],
        ),
        TextField(
          key: const ValueKey('enrollment-pin'),
          controller: _pin,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          autofillHints: const [AutofillHints.oneTimeCode],
          autocorrect: false,
          enableSuggestions: false,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 30,
            letterSpacing: 12,
            fontWeight: FontWeight.w500,
          ),
          decoration: const InputDecoration(
            hintText: '000000',
            counterText: '',
          ),
          onSubmitted: (_) => _pair(),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _enterprise ? Icons.dns_outlined : Icons.cloud_outlined,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              _enterprise ? 'Server propriu' : 'Chimera Cloud',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        if (_enterprise) ...[
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('enterprise-url'),
            controller: _url,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => _pin.clear(),
            decoration: const InputDecoration(
              labelText: 'Adresa serverului Chimera',
              hintText: 'https://chimera.firma.ro',
            ),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    setState(() {
                      _enterprise = false;
                      _url.text = defaultEnrollmentOrigin;
                      _pin.clear();
                      _notice = null;
                    });
                    _syncAction();
                  },
            child: const Text('Folosește Chimera Cloud'),
          ),
        ] else if (_rejectedPins >= 3)
          TextButton(
            onPressed: _busy ? null : _showEnterprise,
            child: const Text('Ești client Enterprise sau self-hosted?'),
          ),
      ],
      if (_notice != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _notice!,
              style: TextStyle(
                color: _error
                    ? Theme.of(context).colorScheme.error
                    : const Color(0xff60a5fa),
              ),
            ),
          ),
        ),
      if (widget.action == null) ...[
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy
              ? null
              : _paired
              ? _continue
              : _pair,
          child: Text(
            _busy
                ? 'Se conectează…'
                : _paired
                ? 'Continuă'
                : 'Conectează',
          ),
        ),
      ],
    ],
  );
}
