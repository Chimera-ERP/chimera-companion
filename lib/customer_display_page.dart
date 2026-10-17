import 'dart:async';
import 'package:flutter/material.dart';
import 'customer_display.dart';
import 'companion_app_bar.dart';
import 'companion_dialog.dart';
import 'android_settings.dart';

class CustomerDisplayPage extends StatefulWidget {
  const CustomerDisplayPage({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<CustomerDisplayPage> createState() => _CustomerDisplayPageState();
}

class _CustomerDisplayPageState extends State<CustomerDisplayPage>
    with WidgetsBindingObserver {
  final _display = CustomerDisplay();
  Map<String, Object?>? _status;
  String? _error;
  Timer? _timer;
  bool _busy = false, _reading = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (_reading) return;
    _reading = true;
    try {
      final value = await _display.status();
      if (mounted) {
        setState(() {
          _status = value;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Nu pot verifica ecranul clientului.');
      }
    } finally {
      _reading = false;
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _error = 'Acțiunea nu a reușit. Reîncearcă.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _content() {
    final state = _status?['state'];
    final enabled = _status?['enabled'] == true;
    final allowed = _status?['backgroundAllowed'] == true;
    final displays = (_status?['displays'] as List?) ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_status == null && _error == null) const LinearProgressIndicator(),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Afișează coșul POS'),
          subtitle: const Text('Coșul POS pe ecranul secundar'),
          value: enabled,
          onChanged: _busy || state == 'unsupported' || _status == null
              ? null
              : (v) => _action(() => _display.setEnabled(v)),
        ),
        const Divider(height: 32),
        Text(switch (state) {
          'ready' => 'Conectat · așteaptă coșul',
          'showing' => 'Coș afișat',
          'permission_required' => 'Afișarea în fundal nu este permisă.',
          'no_display' => 'Niciun ecran secundar detectat.',
          'unsupported' => 'Necesită un dispozitiv Android cu ecran secundar.',
          'error' => 'Android a refuzat deschiderea ecranului.',
          'disabled' => 'Dezactivat',
          _ => _error ?? 'Se verifică ecranul…',
        }, style: Theme.of(context).textTheme.titleMedium),
        if (_status?['pageState'] == 'fallback')
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Pagina personalizată nu s-a încărcat. Folosim pagina inclusă offline.',
            ),
          ),
        for (final display in displays)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.monitor_outlined),
            title: Text('${display['name']}'),
            subtitle: Text('${display['width']} × ${display['height']}'),
          ),
        if (state != 'unsupported' && _status != null) ...[
          const SizedBox(height: 20),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              allowed ? Icons.check_circle_outline : Icons.lock_outline,
            ),
            title: const Text('Afișare în fundal'),
            subtitle: Text(
              allowed ? 'Permisă' : 'Necesară când POS-ul este deschis',
            ),
          ),
          if (!allowed && enabled)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : () => _action(_display.requestPermission),
                child: const Text('Permite afișarea în fundal'),
              ),
            ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Reverifică ecranul'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _action(() => AndroidSettings.open('display')),
                child: const Text('Setări ecran Android'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _action(() => AndroidSettings.open('overlay')),
                child: const Text('Permisiuni Android'),
              ),
            ],
          ),
        ],
        if (_error != null && _status != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_error!, style: const TextStyle(color: Colors.amber)),
          ),
        if (_error != null && _status == null)
          TextButton(onPressed: _refresh, child: const Text('Reîncearcă')),
        if (state == 'error')
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => CompanionDialog(
                    title: 'Diagnostic ecran',
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Închide'),
                      ),
                    ],
                    child: SelectableText(
                      'Cod: ${_status?['errorCode'] ?? 'display_unavailable'}',
                    ),
                  ),
                ),
                child: const Text('Detalii tehnice'),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _content();
    return Scaffold(
      appBar: CompanionAppBar(title: const Text('Ecran client'), busy: _busy),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: _content(),
            ),
          ),
        ),
      ),
    );
  }
}
