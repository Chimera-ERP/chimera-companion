import 'dart:convert';
import 'console/console_service.dart';
import 'console/console_page.dart';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'debug_panel.dart';
import 'hardware/command_journal.dart';
import 'hardware/connection.dart';
import 'hardware/datecs_rou_adapter.dart';
import 'hardware/datecs_device_client.dart';
import 'hardware/tremol_adapter.dart';
import 'hardware/fiscal_device.dart';
import 'pairing.dart';
import 'enrollment_service.dart';
import 'setup_header.dart';
import 'hardware/viva_connection.dart';
import 'tls_setup.dart';
import 'local_tls.dart';
import 'customer_display_page.dart';
import 'companion_dialog.dart';
import 'android_settings.dart';
import 'setup_profile.dart';
import 'companion_scene.dart';
import 'companion_help.dart';
import 'scale_service.dart';
import 'scale_page.dart';
import 'printing/printer_settings_page.dart';

class DeviceSetupPage extends StatefulWidget {
  const DeviceSetupPage({
    super.key,
    this.onCompleted,
    this.initialStep = 0,
    this.scales,
    this.console,
    this.enrollmentService = const SecureEnrollmentService(),
  }) : assert(initialStep >= 0 && initialStep <= 4);
  final VoidCallback? onCompleted;
  final int initialStep;
  final ScaleService? scales;
  final ConsoleService? console;
  final EnrollmentService enrollmentService;
  @override
  State<DeviceSetupPage> createState() => _DeviceSetupPageState();
}

class _DeviceSetupPageState extends State<DeviceSetupPage> {
  static const _storage = FlutterSecureStorage();
  static final _actionButtonStyle = FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(56),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );
  final _fields = {
    for (final key in [
      'host',
      'port',
      'operator',
      'password',
      'tcpPassword',
      'cashCode',
      'cardCode',
      'till',
      'vivaHost',
      'vivaPort',
      'vivaPin',
    ])
      key: TextEditingController(),
  };
  FiscalModel _model = FiscalModel.tremolM20;
  bool _busy = true;
  int _step = 0;
  SetupProfile _profile = SetupProfile.pos;
  SetupAudience _audience = SetupAudience.front;
  bool _printerConfigured = false;
  Set<int> _custom = {2, 3, 6};
  late final ScaleService _scales = widget.scales ?? ScaleService();
  List<int> get _steps {
    final steps = setupSteps(
      _profile,
      _custom,
      audience: _audience,
      equipment: _custom,
    );
    // Explicit ECR/Viva links remain accessible regardless of deployment profile.
    if (!steps.contains(widget.initialStep)) {
      steps.insert(steps.length - 1, widget.initialStep);
    }
    return steps;
  }

  bool _ecrVerified = false;
  bool _vivaEnabled = false;
  bool _hardwareSaved = false;
  Map<String, dynamic> _savedHardware = {};
  final _scroll = ScrollController();
  late final ConsoleService _console = widget.console ?? ConsoleService();
  final _stepAction = ValueNotifier<SetupAction?>(null);
  String? _feedback;
  VoidCallback? _dialogRefresh;
  DatecsProfile _datecsProfile = DatecsProfile.auto;
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _payments = [];
  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    _scales.addListener(_scaleChanged);
    _console.addListener(_scaleChanged);
    _load();
  }

  void _scaleChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    _stepAction.dispose();
    _scroll.dispose();
    _console.removeListener(_scaleChanged);
    if (widget.console == null) _console.close();
    _scales.removeListener(_scaleChanged);
    if (widget.scales == null) _scales.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final savedProfile = await _storage.read(key: 'setup_profile_v1');
      _printerConfigured =
          await _storage.read(key: 'production_printer_v1') != null;
      if (savedProfile != null) {
        final data = jsonDecode(savedProfile) as Map<String, dynamic>;
        _profile = SetupProfile.values.byName(data['profile'] as String);
        _audience =
            SetupAudience.values
                .where((a) => a.name == data['audience'])
                .firstOrNull ??
            audienceFor(_profile);
        if (!profilesFor(_audience).contains(_profile)) {
          _profile = profilesFor(_audience).first;
        }
        _custom = data['version'] == 2 || _profile == SetupProfile.custom
            ? (data['devices'] as List)
                  .whereType<int>()
                  .where(equipmentFor(_audience).contains)
                  .toSet()
            : defaultEquipment(_profile);
      }
      if (widget.initialStep == 0) {
        final savedStep = int.tryParse(
          await _storage.read(key: 'setup_step_v3') ?? '0',
        );
        if (savedProfile == null && (savedStep == null || savedStep == 0)) {
          _step = 0;
        } else if (savedStep != null && _steps.contains(savedStep)) {
          _step = savedStep;
        }
      }
      final saved = await _storage.read(key: 'local_hardware_v1');
      if (saved != null) {
        final value = jsonDecode(saved) as Map<String, dynamic>;
        _savedHardware = value;
        if (value['model'] is String) {
          _model = FiscalModel.values.byName(value['model'] as String);
        }
        _datecsProfile = DatecsProfile.values.byName(
          value['datecsProfile'] as String? ?? 'auto',
        );
        for (final key in _fields.keys) {
          _fields[key]!.text = value[key] as String? ?? '';
        }
        _vivaEnabled =
            value['vivaEnabled'] == 'true' ||
            (value['vivaEnabled'] == null &&
                _fields['vivaHost']!.text.trim().isNotEmpty);
        debugLog('Configurație locală încărcată.');
      }
      _defaults();
    } catch (_) {
      debugLog('Configurația locală nu poate fi citită.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _dialogRefresh?.call();
      }
    }
  }

  void _defaults() {
    if (_fields['vivaHost']!.text.isEmpty) {
      _fields['vivaHost']!.text = '127.0.0.1';
    }
    if (_fields['vivaPort']!.text.isEmpty) _fields['vivaPort']!.text = '9564';
    if (_model != FiscalModel.datecsDp25) {
      for (final entry in {
        'port': '8000',
        'operator': '1',
        'till': '1',
        'cashCode': '0',
        'cardCode': '1',
      }.entries) {
        if (_fields[entry.key]!.text.isEmpty) {
          _fields[entry.key]!.text = entry.value;
        }
      }
      return;
    }
    if (_fields['port']!.text.isEmpty) _fields['port']!.text = '3999';
    for (final entry in {
      'operator': '1',
      'password': '0001',
      'till': '1',
      'cashCode': 'P',
      'cardCode': 'D',
    }.entries) {
      if (_fields[entry.key]!.text.isEmpty) {
        _fields[entry.key]!.text = entry.value;
      }
    }
  }

  LanEndpoint _endpoint() => LanEndpoint(
    host: _fields['host']!.text.trim(),
    port: int.parse(_fields['port']!.text.trim()),
  );
  FiscalConnection _connection({bool discovery = false}) => FiscalConnection(
    id: 'local-ecr',
    model: _model,
    endpoint: _endpoint(),
    operatorNumber: int.parse(_fields['operator']!.text),
    operatorPassword: _fields['password']!.text,
    tcpPassword: _fields['tcpPassword']!.text,
    cashPaymentCode: _fields['cashCode']!.text.trim(),
    cardPaymentCode: _fields['cardCode']!.text.trim(),
    tillNumber: _fields['till']!.text.trim(),
    allowUnknownOperatorPassword: discovery,
  );

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    _dialogRefresh?.call();
    try {
      await action();
    } on TremolLanPasswordRequired catch (error) {
      _ecrVerified = false;
      debugLog(error.toString());
      _feedback = error.toString();
      if (mounted &&
          await _editPassword('tcpPassword', message: error.toString())) {
        _feedback =
            'Parola LAN a fost completată. Apasă Verifică ECR. Operațiunea anterioară nu este repetată automat.';
      }
    } catch (error) {
      var message = '$error';
      for (final key in ['password', 'tcpPassword', 'vivaPin']) {
        final secret = _fields[key]!.text;
        if (secret.isNotEmpty) {
          message = message.replaceAll(secret, '[redactat]');
        }
      }
      _feedback = 'Verificarea a eșuat: $message';
      debugLog(_feedback!);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _dialogRefresh?.call();
      }
    }
  }

  Future<bool> _editPassword(String key, {String? message}) async {
    final lan = key == 'tcpPassword';
    final controller = TextEditingController();
    var visible = false;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(lan ? 'Parolă conexiune LAN' : 'Parolă operator fiscal'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message ??
                      (lan
                          ? 'Parola Ethernet / Wi-Fi configurată pe casa de marcat. Este diferită de parola operatorului.'
                          : 'Parola operatorului ${_fields['operator']!.text} de pe casa de marcat. Nu este parola LAN sau a contului Chimera.'),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: !visible,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => update(() {}),
                  decoration: InputDecoration(
                    labelText: 'Parolă',
                    suffixIcon: IconButton(
                      tooltip: visible ? 'Ascunde parola' : 'Arată parola',
                      onPressed: () => update(() => visible = !visible),
                      icon: Icon(
                        visible ? Icons.visibility_off : Icons.visibility,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Anulează'),
            ),
            FilledButton(
              onPressed: controller.text.isEmpty
                  ? null
                  : () => Navigator.pop(context, controller.text),
              child: const Text('Folosește parola'),
            ),
          ],
        ),
      ),
    );
    // The closing dialog retains its field during the route transition.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (value == null || !mounted) return false;
    setState(() {
      _fields[key]!.text = value;
      _ecrVerified = false;
    });
    return true;
  }

  Widget _passwordAction(String key, String title) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(
      _fields[key]!.text.isEmpty
          ? 'Necompletată'
          : 'Completată · valoare ascunsă',
    ),
    trailing: const Icon(Icons.edit_outlined),
    onTap: _busy
        ? null
        : () async {
            await _editPassword(key);
            _dialogRefresh?.call();
          },
  );

  void _select(Map<String, dynamic> device) {
    _ecrVerified = false;
    _feedback = null;
    _fields['host']!.text = device['host'] as String;
    _fields['port']!.text = '${device['port']}';
    _payments = (device['paymentMethods'] as List? ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();
    _defaults();
    debugLog(
      'Selectat ${device['host']}:${device['port']} · TCP accesibil. Apasă Stare pentru identificarea protocolului.',
    );
  }

  Future<void> _discover() => _run(() async {
    final networks = await DatecsRouAdapter.networkInfo();
    if (networks.isEmpty) {
      _feedback =
          'Nu există o conexiune Wi-Fi sau Ethernet. Deschide setările Wi-Fi și reîncearcă.';
      debugLog(_feedback!);
      return;
    }
    for (final network in networks) {
      debugLog(
        'LAN telefon: ${network['host']}/${network['prefix']}. Scanarea acoperă blocul local de maximum 256 adrese.',
      );
    }
    debugLog('Caut ECR în LAN, pe porturile 3999, 4999 și 8000…');
    final found = (await DatecsRouAdapter.discover())
        .where(
          (device) => _model == FiscalModel.datecsDp25
              ? device['port'] != 8000
              : device['port'] == 8000,
        )
        .toList();
    if (!mounted) return;
    setState(() {
      _devices = found;
      if (found.isNotEmpty) {
        _select(found.first);
      }
    });
    _feedback = found.isEmpty
        ? 'Nicio casă detectată. Verifică rețeaua sau introdu adresa manual.'
        : '${found.length} dispozitive găsite. Selectează casa pentru identificare.';
    debugLog(
      found.isEmpty
          ? 'Niciun port TCP accesibil în LAN-ul afișat. Poți introduce manual IP-ul și portul.'
          : '${found.length} porturi TCP accesibile; protocolul se identifică prin Stare.',
    );
  });

  Future<void> _status() => _run(() async {
    final endpoint = _endpoint();
    debugLog(
      'Conectare la ${endpoint.host}:${endpoint.port} · ${_datecsProfile.name}…',
    );
    if (_model == FiscalModel.datecsDp25) {
      final inspection = await DatecsDeviceClient(
        endpoint,
        profile: _datecsProfile,
      ).inspect(readPayments: true);
      _datecsProfile = inspection.profile;
      debugLog(inspection.description);
      _feedback = inspection.description;
      _ecrVerified = inspection.ready;
      if (mounted) {
        setState(() => _payments = inspection.payments);
      }
      if (inspection.payments.isNotEmpty) {
        debugLog(
          'Plăți citite din ECR: ${inspection.payments.map((p) => '${p['code']}=${p['name']}').join(', ')}',
        );
        final cash = inspection.payments.where((p) => p['code'] == '0');
        final card = inspection.payments.where(
          (p) => RegExp(
            r'card|bancar',
            caseSensitive: false,
          ).hasMatch(p['name'] as String),
        );
        if (cash.length == 1) {
          _fields['cashCode']!.text = cash.first['code'] as String;
        }
        if (card.length == 1) {
          _fields['cardCode']!.text = card.first['code'] as String;
        }
      }
    } else {
      final adapter = TremolAdapter(_connection(discovery: true));
      final status = await adapter.readStatus();
      if (status.ready) {
        final operator = await adapter.readOperatorConfiguration();
        _fields['password']!.text = operator['password']!;
      }
      _ecrVerified = status.ready;
      debugLog(status.description);
      _feedback = status.description;
    }
  });

  Future<void> _save() => _run(() async {
    _hardwareSaved = false;
    // Viva-only / display-only installations must never validate a missing ECR.
    if (_step == 2) _connection();
    if (_step == 3 && _vivaEnabled) {
      final endpoint = vivaEndpoint(
        _fields['vivaHost']!.text,
        _fields['vivaPort']!.text,
      );
      _fields['vivaHost']!.text = endpoint.host;
      _fields['vivaPort']!.text = '${endpoint.port}';
      if (!RegExp(
        r'^[a-fA-F0-9]{64}$',
      ).hasMatch(_fields['vivaPin']!.text.trim())) {
        throw ArgumentError('Invalid certificate fingerprint');
      }
    }
    final next = {
      ..._savedHardware,
      if (_step == 2) ...{
        'model': _model.name,
        'datecsProfile': _datecsProfile.name,
        'paymentCatalog': _payments,
        for (final key in _fields.keys.where((key) => !key.startsWith('viva')))
          key: _fields[key]!.text,
      },
      if (_step == 3) ...{
        'vivaEnabled': '$_vivaEnabled',
        for (final key in _fields.keys.where((key) => key.startsWith('viva')))
          key: _fields[key]!.text,
      },
    };
    await _storage.write(key: 'local_hardware_v1', value: jsonEncode(next));
    _savedHardware = next;
    debugLog('Configurație salvată securizat.');
    _hardwareSaved = true;
  });

  Future<void> _next({bool skipEcr = false}) async {
    if ((_step == 2 && !skipEcr) || _step == 3) await _save();
    if (mounted && (_step < 2 || _step >= 5 || skipEcr || _hardwareSaved)) {
      final next = _steps[_steps.indexOf(_step) + 1];
      if (_step == 5 || _step == 8) {
        await _storage.write(
          key: 'setup_profile_v1',
          value: jsonEncode({
            'version': 2,
            'audience': _audience.name,
            'profile': _profile.name,
            'devices': _custom.toList(),
          }),
        );
      }
      await _storage.write(key: 'setup_step_v3', value: '$next');
      if (!mounted) return;
      _stepAction.value = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      setState(() {
        _step = next;
        _feedback = null;
      });
    }
  }

  Future<void> _checkViva() => _run(() async {
    final result = await checkVivaConnection(
      vivaEndpoint(_fields['vivaHost']!.text, _fields['vivaPort']!.text),
      _fields['vivaPin']!.text.trim(),
    );
    _feedback = result.message;
    debugLog(result.message);
    _feedback = result.message;
    if (!mounted ||
        result.certificate == null ||
        result.trusted ||
        _fields['vivaPin']!.text.trim().isNotEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmă terminalul Viva'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Confirmă că adresa aparține terminalului tău, într-o rețea de încredere. Certificatul va fi fixat pentru conexiunile viitoare. Nu accepta un terminal necunoscut.',
              ),
              const SizedBox(height: 12),
              SelectableText(result.certificate!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Renunță'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm terminalul'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      _fields['vivaPin']!.text = result.certificate!;
      _feedback =
          'Certificat confirmat. Apasă Verifică Viva, apoi Continuă pentru salvare.';
    }
  });

  Future<void> _complete() => _run(() async {
    final directory = await getApplicationSupportDirectory();
    await LocalTls.load(Directory('${directory.path}/local-tls'));
    await _storage.write(key: 'setup_complete_v2', value: 'true');
    await _storage.delete(key: 'setup_step_v3');
    if (!mounted) return;
    debugLog(
      'Configurare salvată: ERP → HTTPS → ECR → Viva. Accesul real din POS trebuie verificat în browser.',
    );
    if (widget.onCompleted != null) {
      widget.onCompleted!();
    } else {
      Navigator.pop(context);
    }
  });

  Future<void> _printX() => _diagnostic('xReport');
  Future<void> _printNonFiscal() => _diagnostic('nonFiscal');

  Future<void> _diagnostic(String operation) => _run(() async {
    final device = FiscalDevice(_connection(), profile: _datecsProfile);
    const lines = [
      'CHIMERA - TEST NEFISCAL',
      'NU ESTE BON FISCAL',
      'FARA INCASARE / FARA VANZARE IN ERP',
    ];
    debugLog('$operation · ${device.name}…');
    final directory = await getApplicationSupportDirectory();
    final random = Random.secure();
    final commandId = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final result =
        await CommandJournal(
          File('${directory.path}/hardware-commands.jsonl'),
        ).execute(
          id: commandId,
          deviceId: device.id,
          operation: operation,
          payload: operation == 'nonFiscal' ? {'lines': lines} : {},
          dispatch: () => operation == 'nonFiscal'
              ? device.nonFiscal(lines)
              : device.report(closeDay: false),
        );
    debugLog(result.message);
  });

  Future<void> _diagnosticDialog() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        _dialogRefresh = () {
          if (context.mounted) update(() {});
        };
        return CompanionDialog(
          title: 'Diagnostic ECR',
          busy: _busy,
          actions: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Închide'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : _printX,
                child: const Text('Printează X'),
              ),
              OutlinedButton(
                onPressed: _busy || !_ecrVerified ? null : _printNonFiscal,
                child: const Text('Test nefiscal'),
              ),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'X nu închide ziua. Testul nefiscal nu înregistrează încasări.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
              if (_feedback != null) Text(_feedback!),
            ],
          ),
        );
      },
    ),
  ).whenComplete(() => _dialogRefresh = null);

  Future<void> _wifi() async {
    try {
      await AndroidSettings.open('wifi');
    } catch (_) {
      if (mounted) {
        setState(() => _feedback = 'Nu pot deschide setările Wi-Fi.');
      }
    }
  }

  Future<void> _advanced({bool viva = false}) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          _dialogRefresh = () {
            if (context.mounted) update(() {});
          };
          void change(VoidCallback action) {
            setState(action);
            update(() {});
          }

          return CompanionDialog(
            title: viva ? 'Setări avansate Viva' : 'Operator și plăți ECR',
            busy: _busy,
            actions: [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('Gata'),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (viva) ...[
                  _input('vivaPin', 'Amprentă certificat SHA-256'),
                  const Align(
                    alignment: Alignment.centerRight,
                    child: CompanionHelpButton(
                      title: 'Despre certificatul terminalului',
                      message:
                          'La verificare, certificatul poate fi preluat de la terminal. Confirmă-l doar dacă adresa este a terminalului tău.',
                    ),
                  ),
                ] else ...[
                  if (_model == FiscalModel.datecsDp25)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DropdownButtonFormField<DatecsProfile>(
                        isExpanded: true,
                        initialValue: _datecsProfile,
                        decoration: const InputDecoration(
                          labelText: 'Protocol Datecs',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: DatecsProfile.auto,
                            child: Text('Detectare automată'),
                          ),
                          DropdownMenuItem(
                            value: DatecsProfile.asciiMx,
                            child: Text('ASCII / MX'),
                          ),
                          DropdownMenuItem(
                            value: DatecsProfile.legacyRou,
                            child: Text('ROU vechi'),
                          ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) => change(() {
                                _datecsProfile = value!;
                                _ecrVerified = false;
                              }),
                      ),
                    ),
                  _row(
                    _input('operator', 'Operator', numeric: true),
                    _input('till', 'Număr casă', numeric: true),
                  ),
                  const SizedBox(height: 12),
                  _passwordAction('password', 'Parolă operator fiscal'),
                  if (_model != FiscalModel.datecsDp25)
                    _passwordAction('tcpPassword', 'Parolă LAN / Wi-Fi'),
                  const SizedBox(height: 12),
                  _row(
                    _input('cashCode', 'Cod numerar'),
                    _input('cardCode', 'Cod card'),
                  ),
                  if (_payments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _payments
                            .map((p) => '${p['code']} · ${p['name']}')
                            .join('   '),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
    _dialogRefresh = null;
  }

  Widget _input(
    String key,
    String label, {
    bool secret = false,
    bool numeric = false,
  }) => TextField(
    controller: _fields[key],
    onChanged: (_) {
      if (!key.startsWith('viva')) {
        setState(() {
          _ecrVerified = false;
          _feedback = null;
        });
      }
    },
    obscureText: secret,
    autocorrect: false,
    enableSuggestions: false,
    enabled: !_busy,
    keyboardType: numeric
        ? TextInputType.number
        : (key == 'host' || key == 'vivaHost')
        ? TextInputType.url
        : TextInputType.text,
    decoration: InputDecoration(labelText: label),
  );
  Widget _row(Widget a, Widget b) => Row(
    children: [
      Expanded(child: a),
      const SizedBox(width: 12),
      Expanded(child: b),
    ],
  );

  Future<void> _back() async {
    if (_busy || _stepAction.value?.busy == true) return;
    final previous = _steps[_steps.indexOf(_step) - 1];
    await _storage.write(key: 'setup_step_v3', value: '$previous');
    if (!mounted) return;
    _stepAction.value = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _step = previous;
      _feedback = null;
    });
  }

  Widget _footer(SetupAction? stepAction) {
    final action = switch (_step) {
      0 || 1 => stepAction ?? const SetupAction('Se încarcă…', null),
      2 => SetupAction(
        _busy
            ? 'Se verifică…'
            : _ecrVerified
            ? 'Continuă'
            : 'Verifică ECR',
        _ecrVerified ? _next : _status,
      ),
      3 => SetupAction(_vivaEnabled ? 'Continuă' : 'Mai târziu', _next),
      4 => SetupAction('Finalizează', _complete),
      _ => SetupAction(
        _step == 5 ||
                _step == 8 ||
                _step == 9 ||
                (_step == 6 && _scales.state.name == 'ready') ||
                (_step == 7 && _printerConfigured) ||
                (_step == 10 && _console.connected)
            ? 'Continuă'
            : 'Mai târziu',
        _next,
      ),
    };
    final short = MediaQuery.sizeOf(context).height < 500;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, short ? 12 : 24, 24, short ? 12 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            style: _actionButtonStyle,
            onPressed: _busy ? null : action.run,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(action.label, textAlign: TextAlign.center),
            ),
          ),
          if (_step == 2) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => _next(skipEcr: true),
              child: const Text('Mai târziu'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SetupAction?>(
    valueListenable: _stepAction,
    builder: (context, stepAction, _) => DebugScaffold(
      busy: _busy || stepAction?.busy == true,
      title: 'Configurare',
      leading: _steps.indexOf(_step) > 0
          ? IconButton(
              tooltip: 'Înapoi',
              constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
              onPressed: _busy || stepAction?.busy == true ? null : _back,
              icon: const Icon(Icons.arrow_back),
            )
          : null,
      actions: [
        if (_audience != SetupAudience.back)
          IconButton(
            tooltip: 'Ecran client',
            onPressed: _busy || stepAction?.busy == true
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CustomerDisplayPage(),
                    ),
                  ),
            icon: const Icon(Icons.monitor_outlined),
          ),
      ],
      body: SetupFrame(
        step: _step,
        steps: _steps,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                  children: [
                    CompanionScene(
                      key: const ValueKey('setup-scene'),
                      scene:
                          (_step == 0 || _step == 1) &&
                              stepAction?.scene != null
                          ? stepAction!.scene!
                          : setupSceneFor(_step, switch (_audience) {
                              SetupAudience.front => CompanionSceneState.front,
                              SetupAudience.back => CompanionSceneState.back,
                              SetupAudience.custom =>
                                CompanionSceneState.custom,
                            }),
                      equipment: _step == 8 ? Set.of(_custom) : null,
                    ),
                    const SizedBox(height: 24),
                    SetupHeader(
                      showScene: false,
                      step: _step,
                      steps: _steps,
                      scene: switch (_audience) {
                        SetupAudience.front => CompanionSceneState.front,
                        SetupAudience.back => CompanionSceneState.back,
                        SetupAudience.custom => CompanionSceneState.custom,
                      },
                    ),
                    if (_step == 5)
                      for (final audience in SetupAudience.values)
                        SetupChoice(
                          title: switch (audience) {
                            SetupAudience.front => 'În fața clientului',
                            SetupAudience.back => 'În producție',
                            SetupAudience.custom => 'Personalizat',
                          },
                          description: switch (audience) {
                            SetupAudience.front =>
                              'Vânzare, încasare și ecran client',
                            SetupAudience.back =>
                              'Bucătărie, bar și pregătirea comenzilor',
                            SetupAudience.custom =>
                              'Toate aplicațiile și echipamentele',
                          },
                          icon: switch (audience) {
                            SetupAudience.front => Icons.storefront_outlined,
                            SetupAudience.back => Icons.soup_kitchen_outlined,
                            SetupAudience.custom => Icons.tune,
                          },
                          selected: _audience == audience,
                          onTap: _busy
                              ? null
                              : () => setState(() {
                                  if (_audience == audience) return;
                                  _audience = audience;
                                  _profile = profilesFor(audience).first;
                                  _custom = defaultEquipment(
                                    _profile,
                                  ).intersection(equipmentFor(audience));
                                }),
                        ),
                    if (_step == 8) ...[
                      const Text(
                        'APLICAȚIE',
                        style: TextStyle(fontSize: 11, letterSpacing: 1.8),
                      ),
                      const SizedBox(height: 12),
                      for (final profile in profilesFor(_audience))
                        SetupChoice(
                          title: profile == SetupProfile.custom
                              ? 'Doar echipamente'
                              : profile.name.toUpperCase(),
                          description: switch (profile) {
                            SetupProfile.pos => 'Punct de vânzare',
                            SetupProfile.kds =>
                              'Ecran de pregătire a comenzilor',
                            SetupProfile.pds => 'Ecran de predare a comenzilor',
                            SetupProfile.custom =>
                              'Conectează perifericele de care ai nevoie',
                          },
                          icon: profile == SetupProfile.custom
                              ? Icons.hub_outlined
                              : Icons.tablet_mac_outlined,
                          selected: _profile == profile,
                          onTap: _busy
                              ? null
                              : () => setState(() => _profile = profile),
                        ),
                      const SizedBox(height: 24),
                      const Text(
                        'ECHIPAMENTE',
                        style: TextStyle(fontSize: 11, letterSpacing: 1.8),
                      ),
                      const SizedBox(height: 8),
                      for (final id in equipmentFor(_audience))
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(setupStepTitles[id]),
                          value: _custom.contains(id),
                          onChanged: _busy
                              ? null
                              : (value) => setState(() {
                                  if (value == true) {
                                    _custom.add(id);
                                  } else {
                                    _custom.remove(id);
                                  }
                                }),
                        ),
                    ],
                    if (_step == 9) const CustomerDisplayPage(embedded: true),
                    if (_step == 10)
                      ConsolePage(
                        service: _console,
                        embedded: true,
                        application: _profile == SetupProfile.pds
                            ? 'PDS'
                            : 'KDS',
                      ),
                    if (_step == 6) ScalePage(service: _scales, embedded: true),
                    if (_step == 7)
                      PrinterSettingsPage(
                        embedded: true,
                        onSaved: () =>
                            setState(() => _printerConfigured = true),
                      ),
                    if (_step == 2) ...[
                      SetupCard(
                        child: DropdownButtonFormField<FiscalModel>(
                          initialValue: _model,
                          key: ValueKey(_model),
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Casă de marcat',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: FiscalModel.tremolM20,
                              child: Text('Tremol M20'),
                            ),
                            DropdownMenuItem(
                              value: FiscalModel.tremolFp21,
                              child: Text('Tremol FP21'),
                            ),
                            DropdownMenuItem(
                              value: FiscalModel.datecsDp25,
                              child: Text('Datecs DP-25'),
                            ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) => setState(() {
                                  if (value == null || value == _model) return;
                                  _model = value;
                                  _ecrVerified = false;
                                  _devices = [];
                                  _payments = [];
                                  _fields['cashCode']!.clear();
                                  _fields['cardCode']!.clear();
                                  _fields['port']!.clear();
                                  _defaults();
                                }),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ...[
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _discover,
                          icon: const Icon(Icons.wifi_find, size: 18),
                          label: const Text('Caută în rețea'),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _busy ? null : _wifi,
                            icon: const Icon(Icons.wifi, size: 18),
                            label: const Text('Setări Wi-Fi'),
                          ),
                        ),
                        for (final device in _devices)
                          ListTile(
                            dense: true,
                            title: Text('${device['host']}:${device['port']}'),
                            subtitle: Text(
                              device['description'] as String? ??
                                  'TCP accesibil',
                            ),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: _busy
                                ? null
                                : () => setState(() => _select(device)),
                          ),
                        const SizedBox(height: 12),
                      ],
                      SetupCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'ADRESĂ DISPOZITIV',
                              style: TextStyle(
                                fontSize: 10,
                                letterSpacing: 1.3,
                                color: Colors.white54,
                              ),
                            ),
                            const SizedBox(height: 12),
                            _row(
                              _input('host', 'IP local ECR'),
                              _input('port', 'Port', numeric: true),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_feedback != null)
                        SetupCard(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _ecrVerified
                                    ? Icons.check_circle_outline
                                    : Icons.info_outline,
                                size: 20,
                                color: _ecrVerified
                                    ? const Color(0xff79dbc3)
                                    : Colors.amber,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _feedback!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_model == FiscalModel.datecsDp25)
                        TextButton(
                          onPressed: _busy ? null : () => _diagnosticDialog(),
                          child: const Text('Diagnostic ECR'),
                        ),
                      const SizedBox(height: 12),
                    ],
                    if (_step == 2)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _busy ? null : _advanced,
                          icon: const Icon(Icons.tune, size: 18),
                          label: const Text('Operator și setări avansate'),
                        ),
                      ),
                    if (_step == 3)
                      SetupCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Folosește Viva Terminal'),
                              subtitle: const Text(
                                'Pe acest Android sau pe un terminal din LAN',
                              ),
                              value: _vivaEnabled,
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(() {
                                      _vivaEnabled = value;
                                      _feedback = null;
                                    }),
                            ),
                            if (_vivaEnabled) ...[
                              const Text(
                                'Activează Peer to Peer în aplicația Viva Terminal.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white60,
                                ),
                              ),
                              const SizedBox(height: 12),
                              _row(
                                _input('vivaHost', 'IP local Viva'),
                                _input('vivaPort', 'Port HTTPS', numeric: true),
                              ),
                              const Text(
                                'Implicit: Viva pe acest Android.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white60,
                                ),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: _busy || !_vivaEnabled
                                    ? null
                                    : _checkViva,
                                icon: const Icon(Icons.wifi_tethering),
                                label: const Text('Verifică Viva · fără plată'),
                              ),
                              const SizedBox(height: 12),
                              TextButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _advanced(viva: true),
                                icon: const Icon(Icons.tune, size: 18),
                                label: const Text('Setări avansate Viva'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    if (_step == 3 && _feedback != null)
                      Text(
                        _feedback!,
                        style: const TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                        ),
                      ),
                    if (_step == 0)
                      SetupCard(
                        child: PairingPage(
                          showScene: false,
                          service: widget.enrollmentService,
                          embedded: true,
                          onCompleted: _next,
                          action: _stepAction,
                        ),
                      ),
                    if (_step == 1)
                      SetupCard(
                        child: TlsSetup(
                          showScene: false,
                          onCompleted: _next,
                          action: _stepAction,
                        ),
                      ),
                    if (_step == 4) ...[
                      const Text(
                        'Dispozitivele neconfigurate pot fi adăugate ulterior din pagina principală.',
                      ),
                      const SizedBox(height: 16),
                      if (_steps.contains(2))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.receipt_long_outlined),
                          title: const Text('Casa de marcat'),
                          subtitle: Text(
                            _savedHardware['host'] is String &&
                                    (_savedHardware['host'] as String)
                                        .isNotEmpty
                                ? 'Configurată'
                                : 'De configurat mai târziu',
                          ),
                        ),
                      if (_steps.contains(3))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.credit_card),
                          title: const Text('Terminal de plată'),
                          subtitle: Text(
                            _savedHardware['vivaEnabled'] == 'true'
                                ? 'Configurat'
                                : 'De configurat mai târziu',
                          ),
                        ),
                      if (_steps.contains(6))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.scale_outlined),
                          title: const Text('Cântar'),
                          subtitle: Text(
                            _scales.selectedName ?? 'De configurat mai târziu',
                          ),
                        ),
                      if (_steps.contains(7))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.print_outlined),
                          title: const Text('Imprimantă producție'),
                          subtitle: Text(
                            _printerConfigured
                                ? 'Configurată · imprimarea fizică neverificată'
                                : 'De configurat mai târziu',
                          ),
                        ),
                      if (_steps.contains(10))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.keyboard_outlined),
                          title: const Text('Tastatură custom'),
                          subtitle: Text(
                            _console.connected
                                ? 'Conectată'
                                : 'De configurat mai târziu',
                          ),
                        ),
                      if (_audience != SetupAudience.back) const Divider(),
                      if (_audience != SetupAudience.back)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.monitor_outlined),
                          title: const Text('Ecran client'),
                          subtitle: const Text(
                            'Permite afișarea în fundal înainte de a deschide POS-ul.',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _busy
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const CustomerDisplayPage(),
                                  ),
                                ),
                        ),
                      if (_feedback != null)
                        Text(
                          _feedback!,
                          style: const TextStyle(color: Colors.amber),
                        ),
                    ],
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
              _footer(stepAction),
            ],
          ),
        ),
      ),
    ),
  );
}
