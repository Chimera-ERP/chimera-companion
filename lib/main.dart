import 'dart:convert';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:forui/forui.dart';
import 'device_setup.dart';
import 'pairing.dart';
import 'debug_panel.dart';
import 'local_bridge.dart';
import 'enrollment.dart';
import 'app_updates.dart';
import 'service_console.dart';
import 'diagnostic_outbox.dart';

void main() {
  final previous=FlutterError.onError;
  FlutterError.onError=(details) {
    unawaited(reportCompanionError?.call('framework_error','Flutter ${details.exception.runtimeType}').catchError((_){ }));
    previous?.call(details);
  };
  final previousPlatform=PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError=(error,stack) {
    unawaited(reportCompanionError?.call('uncaught_error','Runtime ${error.runtimeType}').catchError((_){ }));
    return previousPlatform?.call(error,stack)??false;
  };
  runApp(const CompanionApp());
}

class CompanionApp extends StatelessWidget {
  const CompanionApp({super.key});
  @override
  Widget build(BuildContext context) {
    final theme = FTheme.neutral.dark.touch;
    return MaterialApp(
      title: 'Chimera Companion',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: theme.toApproximateMaterialTheme().copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xffeeeeee),
            foregroundColor: const Color(0xff171717),
            disabledBackgroundColor: const Color(0xff303030),
            disabledForegroundColor: const Color(0xffa3a3a3),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xffeeeeee),
            foregroundColor: const Color(0xff171717),
          ),
        ),
      ),
      builder: (_, child) => FTheme(data: theme, child: child!),
      home: const CompanionEntry(),
    );
  }
}

class CompanionEntry extends StatefulWidget {
  const CompanionEntry({super.key});
  @override
  State<CompanionEntry> createState() => _CompanionEntryState();
}

class _CompanionEntryState extends State<CompanionEntry> {
  bool? _complete;
  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final value = await const FlutterSecureStorage().read(
      key: 'setup_complete_v2',
    );
    final paired = hasSavedEnrollment(
      await const FlutterSecureStorage().read(key: 'erp_pairing_v1'),
    );
    if (!paired) {
      await const FlutterSecureStorage().write(
        key: 'setup_step_v3',
        value: '0',
      );
    }
    if (mounted) setState(() => _complete = value == 'true' && paired);
  }

  @override
  Widget build(BuildContext context) => _complete == null
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : _complete == true
      ? const CompanionHome()
      : DeviceSetupPage(
          onCompleted: () {
            if (mounted) setState(() => _complete = true);
          },
        );
}

class CompanionHome extends StatefulWidget {
  const CompanionHome({super.key});
  @override
  State<CompanionHome> createState() => _CompanionHomeState();
}

class _CompanionHomeState extends State<CompanionHome> {
  final _bridge = LocalBridge();
  int? _selected;
  String? _error;
  static const _titles = [
    'Chimera',
    'Casa de marcat',
    'Terminal de plată',
    'POS',
  ];
  @override
  void initState() {
    super.initState();
    _bridge.addListener(_update);
    _start();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    try {
      await _bridge.start();
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Conexiunea POS necesită un certificat HTTPS local valid.',
        );
      }
    }
  }

  @override
  void dispose() {
    _bridge.removeListener(_update);
    _bridge.close();
    super.dispose();
  }

  Future<void> _open(Widget page) async {
    if (_bridge.busy) return;
    _bridge.configurationOpen = true;
    try {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => page));
    } finally {
      _bridge.configurationOpen = false;
      if (mounted) {
        await _bridge.maintainConnectivity();
        await _bridge.refresh();
      }
    }
  }

  FTile _row(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback action, {
    String? state,
  }) => FTile(
    title: Text(title),
    subtitle: Text(subtitle),
    prefix: Icon(icon, size: 20),
    suffix: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              state,
              style: TextStyle(
                fontSize: 12,
                color: state == 'Conectat'
                    ? Colors.green.shade300
                    : Colors.grey,
              ),
            ),
          ),
        const Icon(Icons.chevron_right, size: 18),
      ],
    ),
    onPress: action,
  );
  void _select(int section, bool wide) {
    if (wide) {
      setState(() => _selected = section);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimatedBuilder(
          animation: _bridge,
          builder: (_, _) => Scaffold(
            appBar: AppBar(title: Text(_titles[section])),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _detail(section),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _diagnostics() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CompanionDiagnostics(bridge: _bridge),
    ),
  );
  Widget _detail(int section) => switch (section) {
    0 => FTileGroup(
      children: [
        _row(
          'Asociere',
          _bridge.location,
          Icons.link,
          () => _open(const PairingPage()),
        ),
        FTile(
          title: const Text('Conexiune ERP'),
          subtitle: Text(
            _bridge.erpConnected ? 'Disponibilă' : 'Indisponibilă',
          ),
        ),
        FTile(
          title: const Text('Autorizare offline'),
          subtitle: const Text('În curs de implementare'),
          enabled: false,
        ),
      ],
    ),
    1 => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FTileGroup(
          label: const Text('Conexiune'),
          children: [
            FTile(
              title: Text('${_bridge.ecr['name']}'),
              subtitle: Text('${_bridge.ecr['message']}'),
            ),
            _row(
              'Configurează casa',
              'Adresă și operator',
              Icons.settings_outlined,
              () => _open(const DeviceSetupPage(initialStep: 2)),
            ),
          ],
        ),
        const SizedBox(height: 24),
        FTileGroup(
          label: const Text('Întreținere'),
          children: [
            FTile(
              title: const Text('Deblocare și data / ora'),
              subtitle: const Text(
                'Necesită implementarea autorizării și a fluxurilor ECR.',
              ),
              enabled: false,
            ),
            _row(
              'Diagnostic',
              'Comenzi și rezultate',
              Icons.terminal,
              _diagnostics,
            ),
          ],
        ),
      ],
    ),
    2 => FTileGroup(
      children: [
        FTile(
          title: const Text('Viva Terminal'),
          subtitle: Text('${_bridge.payment['message']}'),
        ),
        _row(
          'Configurează terminalul',
          'Pe acest telefon sau în LAN',
          Icons.settings_outlined,
          () => _open(const DeviceSetupPage(initialStep: 3)),
        ),
      ],
    ),
    _ => FTileGroup(
      children: [
        FTile(
          title: const Text('Server local HTTPS'),
          subtitle: Text(_bridge.port == null ? 'Oprit' : 'Disponibil'),
        ),
        FTile(
          title: const Text('Adresa conexiunii'),
          subtitle: SelectableText(_bridge.localUrls.join('\n')),
        ),
        FTile(
          title: const Text('Certificat și DNS'),
          subtitle: Text(_bridge.tlsStatus),
        ),
        _row(
          'Configurează HTTPS',
          'Conexiune securizată pentru POS',
          Icons.security,
          () => _open(const DeviceSetupPage(initialStep: 1)),
        ),
        FTile(
          title: const Text('Ultima comunicare POS'),
          subtitle: Text(
            _bridge.lastPosRequest?.toLocal().toString() ??
                'În așteptarea primei comenzi',
          ),
        ),
        _row(
          'Copiază adresa',
          'Pentru configurarea POS',
          Icons.copy_outlined,
          () {
            if (_bridge.localUrls.isNotEmpty) {
              Clipboard.setData(ClipboardData(text: _bridge.localUrls.first));
            }
          },
        ),
      ],
    ),
  };
  @override
  Widget build(BuildContext context) => FTheme(
    data: FTheme.neutral.dark.touch,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Companion'),
        actions: [
          CompanionUpdateButton(isBusy: () => _bridge.busy || _bridge.configurationOpen,
            setUpdating: (value) { _bridge.configurationOpen = value; if (mounted) setState(() {}); }),
          IconButton(tooltip: 'Consolă ECR · DEV', icon: const Icon(Icons.terminal),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => ServiceConsole(bridge: _bridge)))),
          IconButton(
            tooltip: 'Actualizează conexiunile',
            icon: const Icon(Icons.refresh),
            onPressed: _bridge.busy
                ? null
                : () => _bridge.port == null ? _start() : _bridge.refresh(),
          ),
          IconButton(
            tooltip: 'Diagnostic',
            icon: const Icon(Icons.terminal),
            onPressed: _diagnostics,
          ),
          IconButton(
            tooltip: 'Configurare',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _open(const DeviceSetupPage()),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (_, constraints) {
            final wide = constraints.maxWidth >= 700;
            final connections = SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _bridge.location,
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  FTileGroup(
                    children: [
                      _row(
                        'Chimera',
                        _bridge.location,
                        Icons.cloud_outlined,
                        () => _select(0, wide),
                        state: _bridge.erpConnected ? 'Conectat' : 'Offline',
                      ),
                      _row(
                        'Casa de marcat',
                        '${_bridge.ecr['name']}',
                        Icons.receipt_long_outlined,
                        () => _select(1, wide),
                        state: _bridge.ecr['state'] == 'ready'
                            ? 'Conectat'
                            : 'De verificat',
                      ),
                      _row(
                        'Terminal de plată',
                        'Viva Terminal',
                        Icons.contactless_outlined,
                        () => _select(2, wide),
                        state: _bridge.payment['state'] == 'disabled'
                            ? 'Opțional'
                            : _bridge.payment['state'] == 'ready'
                            ? 'Conectat'
                            : 'De verificat',
                      ),
                      _row(
                        'POS',
                        _bridge.port == null
                            ? 'Server HTTPS oprit'
                            : 'Server HTTPS disponibil',
                        Icons.point_of_sale_outlined,
                        () => _select(3, wide),
                      ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(_error!),
                    ),
                  if (_bridge.activeCommand != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(
                        'Operațiune în curs: ${_bridge.activeCommand!['operation']}',
                      ),
                    ),
                ],
              ),
            );
            return wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 360, child: connections),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _selected == null
                              ? const Text(
                                  'Selectează o conexiune pentru detalii.',
                                )
                              : _detail(_selected!),
                        ),
                      ),
                    ],
                  )
                : connections;
          },
        ),
      ),
    ),
  );
}

class CompanionDiagnostics extends StatefulWidget {
  const CompanionDiagnostics({super.key, required this.bridge});
  final LocalBridge bridge;
  @override
  State<CompanionDiagnostics> createState() => _CompanionDiagnosticsState();
}

class _CompanionDiagnosticsState extends State<CompanionDiagnostics> {
  bool _errorsOnly = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Diagnostic'),
      actions: [
        IconButton(
          tooltip: 'Copiază jurnalul',
          icon: const Icon(Icons.copy_outlined),
          onPressed: () => Clipboard.setData(
            ClipboardData(text: jsonEncode(widget.bridge.history)),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: widget.bridge,
        builder: (_, _) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Doar probleme'),
              value: _errorsOnly,
              onChanged: (value) => setState(() => _errorsOnly = value),
            ),
            for (final entry in widget.bridge.history.where(
              (e) => !_errorsOnly || e['outcome'] != 'succeeded',
            ))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${entry['operation']} · ${entry['outcome']}'),
                subtitle: Text('${entry['message']}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Rezultatul comenzii')),
                      body: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: SelectableText(
                          const JsonEncoder.withIndent('  ').convert(entry),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.bridge.history.isEmpty)
              const Text('Nu există comenzi înregistrate.'),
            const SizedBox(height: 24),
            const Text('Mesaje conexiune'),
            const SizedBox(height: 12),
            ValueListenableBuilder<List<String>>(
              valueListenable: debugMessages,
              builder: (_, messages, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final message in messages.reversed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(
                        message,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
