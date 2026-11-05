import 'dart:convert';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:forui/forui.dart';
import 'device_setup.dart';
import 'companion_scene.dart';
import 'pairing.dart';
import 'debug_panel.dart';
import 'local_bridge.dart';
import 'enrollment.dart';
import 'companion_app_bar.dart';
import 'service_console.dart';
import 'diagnostic_outbox.dart';
import 'customer_display_page.dart';
import 'printing/printer_settings_page.dart';
import 'scale_page.dart';
import 'console/console_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    unawaited(
      reportCompanionError
          ?.call('framework_error', 'Flutter ${details.exception.runtimeType}')
          .catchError((_) {}),
    );
    previous?.call(details);
  };
  final previousPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(
      reportCompanionError
          ?.call('uncaught_error', 'Runtime ${error.runtimeType}')
          .catchError((_) {}),
    );
    return previousPlatform?.call(error, stack) ?? false;
  };
  // A boot-started engine has no Flutter view and cannot wait for widget initState.
  // The UI attaches to this same bridge later; LocalBridge.start coalesces callers.
  final bridge = LocalBridge();
  unawaited(resumeSavedCompanion(bridge));
  runApp(CompanionApp(bridge: bridge));
}

Future<void> resumeSavedCompanion(
  LocalBridge bridge, {
  FlutterSecureStorage storage = const FlutterSecureStorage(),
}) async {
  try {
    if (await storage.read(key: 'setup_complete_v2') != 'true' ||
        !hasSavedEnrollment(await storage.read(key: 'erp_pairing_v1'))) {
      return;
    }
    await bridge.start();
  } catch (_) {
    // Keep the cached native display available; opening the UI offers retry.
    debugLog('Pornirea conexiunii POS necesită verificarea configurației.');
  }
}

class CompanionApp extends StatefulWidget {
  const CompanionApp({super.key, this.bridge, this.home});
  final LocalBridge? bridge;
  final Widget? home;
  @override
  State<CompanionApp> createState() => _CompanionAppState();
}

class _CompanionAppState extends State<CompanionApp> {
  late final _bridge = widget.bridge ?? LocalBridge();
  bool _previousConfigurationOpen = false;
  void _updating(bool value) {
    if (value) _previousConfigurationOpen = _bridge.configurationOpen;
    _bridge.configurationOpen = value || _previousConfigurationOpen;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FThemeData(
      touch: true,
      colors: FColors.neutralDark.copyWith(
        background: Colors.black,
        card: const Color(0xff090d14),
        primary: const Color(0xff2563eb),
        primaryForeground: Colors.white,
        secondary: const Color(0xff111827),
        muted: const Color(0xff111827),
        border: const Color(0xff1e293b),
        mutedForeground: const Color(0xff94a3b8),
      ),
    );
    return MaterialApp(
      title: 'Chimera Companion',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: theme.toApproximateMaterialTheme().copyWith(
        scaffoldBackgroundColor: const Color(0xff000000),
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xff090d14),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
            side: BorderSide(color: Color(0xff1e293b)),
          ),
        ),
        dividerColor: const Color(0xff1e293b),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff000000),
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
          elevation: 0,
          titleTextStyle: TextStyle(
            fontFamily: 'packages/forui/Inter',
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xfff8fafc),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff090d14),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 18,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xff1e293b)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xff60a5fa), width: 2),
          ),
        ),
        listTileTheme: const ListTileThemeData(
          iconColor: Color(0xff94a3b8),
          titleTextStyle: TextStyle(
            fontFamily: 'packages/forui/Inter',
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: Color(0xfff8fafc),
          ),
          subtitleTextStyle: TextStyle(
            fontFamily: 'packages/forui/Inter',
            fontSize: 13,
            height: 1.5,
            color: Color(0xff94a3b8),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xff2563eb),
            foregroundColor: const Color(0xffffffff),
            disabledBackgroundColor: const Color(0xff303030),
            disabledForegroundColor: const Color(0xffa3a3a3),
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xff2563eb),
            foregroundColor: const Color(0xffffffff),
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: const Color(0xff60a5fa),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xff60a5fa),
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      builder: (_, child) => FTheme(
        data: theme,
        child: CompanionUpdateScope(
          isBusy: () => _bridge.busy,
          setUpdating: _updating,
          child: CompanionMotionScope(child: child!),
        ),
      ),
      home: widget.home ?? CompanionEntry(bridge: _bridge),
    );
  }
}

class CompanionEntry extends StatefulWidget {
  const CompanionEntry({super.key, this.bridge});
  final LocalBridge? bridge;
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
      ? const Scaffold(
          body: Center(
            child: CompanionScene(
              scene: CompanionSceneState.splash,
              height: 320,
            ),
          ),
        )
      : _complete == true
      ? CompanionHome(bridge: widget.bridge)
      : DeviceSetupPage(
          scales: widget.bridge?.scales,
          console: widget.bridge?.console,
          onCompleted: () {
            if (mounted) setState(() => _complete = true);
          },
        );
}

class CompanionHome extends StatefulWidget {
  const CompanionHome({super.key, this.bridge});
  final LocalBridge? bridge;
  @override
  State<CompanionHome> createState() => _CompanionHomeState();
}

class _CompanionHomeState extends State<CompanionHome> {
  late final LocalBridge _bridge;
  int? _selected;
  final _detailKey = GlobalKey();
  String? _error;
  Timer? _scaleFreshness;
  static const _titles = [
    'Chimera',
    'Casa de marcat',
    'Terminal de plată',
    'POS',
    'Ecran client',
    'Cântar',
    'Imprimantă producție',
    'Consolă KDS',
  ];
  @override
  void initState() {
    super.initState();
    _bridge = widget.bridge ?? LocalBridge();
    _bridge.addListener(_update);
    _bridge.scales.addListener(_update);
    _bridge.console.addListener(_update);
    _scaleFreshness = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_bridge.scales.reading != null) _update();
    });
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
    _bridge.scales.removeListener(_update);
    _bridge.console.removeListener(_update);
    _scaleFreshness?.cancel();
    if (widget.bridge == null) unawaited(_bridge.close());
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
  void _select(int section, bool wide) => setState(() => _selected = section);

  void _diagnostics() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CompanionDiagnostics(bridge: _bridge),
    ),
  );
  Widget _detail(int section) => switch (section) {
    7 => ConsolePage(service: _bridge.console, embedded: true),
    5 => ScalePage(service: _bridge.scales, embedded: true),
    6 => const PrinterSettingsPage(embedded: true),
    4 => const CustomerDisplayPage(embedded: true),
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
              () => _open(
                DeviceSetupPage(
                  initialStep: 2,
                  scales: _bridge.scales,
                  console: _bridge.console,
                ),
              ),
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
          () => _open(
            DeviceSetupPage(
              initialStep: 3,
              scales: _bridge.scales,
              console: _bridge.console,
            ),
          ),
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
          () => _open(
            DeviceSetupPage(
              initialStep: 1,
              scales: _bridge.scales,
              console: _bridge.console,
            ),
          ),
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 840;
      final detail = _selected;
      final connections = ListView(
        padding: const EdgeInsets.all(20),
        children: [
          CompanionScene(
            height: wide ? 155 : 180,
            scene: _error != null
                ? CompanionSceneState.attention
                : _bridge.busy
                ? CompanionSceneState.connecting
                : CompanionSceneState.custom,
          ),
          const SizedBox(height: 20),
          Text(_bridge.location, style: Theme.of(context).textTheme.bodySmall),
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
                state: _bridge.ecr['state'] == 'unconfigured'
                    ? 'Opțional'
                    : _bridge.ecr['state'] == 'ready'
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
              _row(
                'Cântar',
                _bridge.scales.selectedName ?? 'Bluetooth · neconfigurat',
                Icons.scale_outlined,
                () => _select(5, wide),
                state: _bridge.scales.state.name == 'ready'
                    ? (_bridge.scales.reading != null &&
                              DateTime.now().difference(
                                    _bridge.scales.reading!.observedAt,
                                  ) <=
                                  const Duration(seconds: 2)
                          ? '${_bridge.scales.reading!.net} g'
                          : 'Conectat')
                    : _bridge.scales.state.name == 'connecting' ||
                          _bridge.scales.connecting
                    ? 'Conectare…'
                    : _bridge.scales.state.name == 'error'
                    ? 'De verificat'
                    : _bridge.scales.selectedId == null
                    ? 'Opțional'
                    : 'Deconectat',
              ),
              _row(
                'Ecran client',
                'Coș și total',
                Icons.monitor_outlined,
                () => _select(4, wide),
              ),
              _row(
                'Imprimantă producție',
                'Tichete și etichete · LAN',
                Icons.print_outlined,
                () => _select(6, wide),
              ),
              _row(
                'Consolă KDS',
                'Ulanzi · USB',
                Icons.keyboard_outlined,
                () => _select(7, wide),
                state: _bridge.console.connected ? 'Conectat' : 'Opțional',
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
      );
      final content = Align(
        key: _detailKey,
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide && detail != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Text(
                      _titles[detail],
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                if (detail == null)
                  const Text('Selectează o conexiune.')
                else
                  _detail(detail),
              ],
            ),
          ),
        ),
      );
      return PopScope(
        canPop: detail == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _selected = null);
        },
        child: Scaffold(
          appBar: CompanionAppBar(
            title: Text(
              !wide && detail != null ? _titles[detail] : 'Companion',
            ),
            leading: !wide && detail != null
                ? IconButton(
                    tooltip: 'Înapoi',
                    onPressed: () => setState(() => _selected = null),
                    icon: const Icon(Icons.arrow_back),
                  )
                : null,
            autoCheck: true,
            actions: [
              IconButton(
                tooltip: 'Actualizează conexiunile',
                icon: const Icon(Icons.refresh),
                onPressed: _bridge.busy
                    ? null
                    : () => _bridge.port == null ? _start() : _bridge.refresh(),
              ),
              PopupMenuButton<String>(
                tooltip: 'Mai multe',
                enabled: !_bridge.busy,
                onSelected: (value) {
                  if (value == 'settings') {
                    _open(
                      DeviceSetupPage(
                        scales: _bridge.scales,
                        console: _bridge.console,
                      ),
                    );
                  }
                  if (value == 'diagnostic') _diagnostics();
                  if (value == 'console') {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ServiceConsole(bridge: _bridge),
                      ),
                    );
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'settings', child: Text('Configurare')),
                  PopupMenuItem(value: 'diagnostic', child: Text('Diagnostic')),
                  PopupMenuItem(
                    value: 'console',
                    child: Text('Consolă ECR · DEV'),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 320, child: connections),
                      const VerticalDivider(width: 1),
                      Expanded(child: content),
                    ],
                  )
                : detail == null
                ? connections
                : content,
          ),
        ),
      );
    },
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
    appBar: CompanionAppBar(
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
                      appBar: const CompanionAppBar(
                        title: Text('Rezultatul comenzii'),
                      ),
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
