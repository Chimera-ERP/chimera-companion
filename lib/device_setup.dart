import 'dart:convert';
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
import 'setup_header.dart';
import 'hardware/viva_connection.dart';
import 'tls_setup.dart';
import 'local_tls.dart';

class DeviceSetupPage extends StatefulWidget {
  const DeviceSetupPage({super.key, this.onCompleted, this.initialStep = 0})
    : assert(initialStep >= 0 && initialStep <= 4);
  final VoidCallback? onCompleted;
  final int initialStep;
  @override
  State<DeviceSetupPage> createState() => _DeviceSetupPageState();
}

class _DeviceSetupPageState extends State<DeviceSetupPage> {
  static const _storage = FlutterSecureStorage();
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
  bool _ecrVerified = false;
  bool _vivaEnabled = false;
  bool _hardwareSaved = false;
  String? _feedback;
  DatecsProfile _datecsProfile = DatecsProfile.auto;
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _payments = [];
  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    _load();
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (widget.initialStep == 0) {
        final savedStep = int.tryParse(
          await _storage.read(key: 'setup_step_v3') ?? '0',
        );
        if (savedStep != null && savedStep >= 0 && savedStep <= 4) {
          _step = savedStep;
        }
      }
      final saved = await _storage.read(key: 'local_hardware_v1');
      if (saved != null) {
        final value = jsonDecode(saved) as Map<String, dynamic>;
        _model = FiscalModel.values.byName(value['model'] as String);
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
    onTap: _busy ? null : () => _editPassword(key),
  );

  void _select(Map<String, dynamic> device) {
    _ecrVerified = false;
    _feedback = null;
    _fields['host']!.text = device['host'] as String;
    _fields['port']!.text = '${device['port']}';
    _payments = (device['paymentMethods'] as List)
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
      debugLog('Telefonul nu are o conexiune Wi-Fi/Ethernet cu IPv4 local.');
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
    _connection();
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
    await _storage.write(
      key: 'local_hardware_v1',
      value: jsonEncode({
        'model': _model.name,
        'datecsProfile': _datecsProfile.name,
        'paymentCatalog': _payments,
        'vivaEnabled': '$_vivaEnabled',
        for (final key in _fields.keys) key: _fields[key]!.text,
      }),
    );
    debugLog('Configurație salvată securizat.');
    _hardwareSaved = true;
  });

  Future<void> _next() async {
    if (_step == 2 || _step == 3) await _save();
    if (mounted && (_step < 2 || _hardwareSaved)) {
      await _storage.write(key: 'setup_step_v3', value: '${_step + 1}');
      if (!mounted) return;
      setState(() {
        _step++;
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

  Widget _input(
    String key,
    String label, {
    bool secret = false,
    bool numeric = false,
  }) => TextField(
    controller: _fields[key],
    onChanged: (_) {
      if (key == 'host' || key == 'port') {
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

  @override
  Widget build(BuildContext context) => DebugScaffold(
    title: 'Companion · configurare',
    body: Column(
      children: [
        Expanded(
          child: ListView(
            key: ValueKey(_step),
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            children: [
              SetupHeader(step: _step),
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
                  for (final device in _devices)
                    ListTile(
                      dense: true,
                      title: Text('${device['host']}:${device['port']}'),
                      subtitle: Text(
                        device['description'] as String? ?? 'TCP accesibil',
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
                            style: const TextStyle(fontSize: 12, height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_model == FiscalModel.datecsDp25)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text(
                      'Diagnostic și tipărire',
                      style: TextStyle(fontSize: 13),
                    ),
                    children: [
                      OutlinedButton(
                        onPressed: _busy ? null : _printX,
                        child: const Text('Printează X'),
                      ),
                      OutlinedButton(
                        onPressed: _busy || !_ecrVerified
                            ? null
                            : _printNonFiscal,
                        child: const Text('Test nefiscal'),
                      ),
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text(
                          'X nu închide ziua. Testul nefiscal nu înregistrează încasări.',
                          style: TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
              ],
              if (_step == 2)
                ExpansionTile(
                  initiallyExpanded: false,
                  tilePadding: EdgeInsets.zero,
                  title: const Text(
                    'Operator și setări avansate',
                    style: TextStyle(fontSize: 13),
                  ),
                  childrenPadding: const EdgeInsets.only(top: 16, bottom: 16),
                  children: [
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
                              : (value) =>
                                    setState(() => _datecsProfile = value!),
                        ),
                      ),
                    _row(
                      _input('operator', 'Operator', numeric: true),
                      _input('till', 'Număr casă', numeric: true),
                    ),
                    const SizedBox(height: 12),
                    _passwordAction('password', 'Parolă operator fiscal'),
                    if (_model != FiscalModel.datecsDp25)
                      _passwordAction(
                        'tcpPassword',
                        'Parolă conexiune LAN / Wi-Fi',
                      ),
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
                ),
              if (_step == 3)
                SetupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'TERMINAL LOCAL',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.3,
                          color: Colors.white54,
                        ),
                      ),
                      const SizedBox(height: 16),
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
                      const Text(
                        'În Viva Terminal: More → Integrations → Viva Peer to Peer → Enable Peer to Peer → Use device as PIN pad. PIN-ul din Viva protejează setările; nu este amprenta certificatului HTTPS.',
                        style: TextStyle(fontSize: 12, color: Colors.white60),
                      ),
                      const SizedBox(height: 12),
                      _row(
                        _input('vivaHost', 'IP local Viva'),
                        _input('vivaPort', 'Port HTTPS', numeric: true),
                      ),
                      const Text(
                        '127.0.0.1:9564 = Viva pe același Android. Pentru alt terminal, introdu IP-ul și portul din Server information.',
                        style: TextStyle(fontSize: 12, color: Colors.white60),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _busy || !_vivaEnabled ? null : _checkViva,
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text('Verifică Viva · fără plată'),
                      ),
                      const SizedBox(height: 12),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          'Certificat HTTPS',
                          style: TextStyle(fontSize: 13),
                        ),
                        subtitle: const Text(
                          'Necesar pentru o conexiune securizată',
                          style: TextStyle(fontSize: 11),
                        ),
                        children: [
                          _input('vivaPin', 'Amprentă certificat SHA-256'),
                        ],
                      ),
                    ],
                  ),
                ),
              if (_step == 3 && _feedback != null)
                Text(
                  _feedback!,
                  style: const TextStyle(color: Colors.amber, fontSize: 12),
                ),
              if (_step == 0)
                SetupCard(
                  child: PairingPage(embedded: true, onCompleted: _next),
                ),
              if (_step == 1) SetupCard(child: TlsSetup(onCompleted: _next)),
              if (_step == 4) ...[
                const Text(
                  'Configurația este pregătită pentru verificare din POS. Certificatul valid și heartbeat-ul ERP nu confirmă accesul browserului la Companion.',
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _complete,
                  child: const Text('Validează configurația și termină'),
                ),
                if (_feedback != null)
                  Text(_feedback!, style: const TextStyle(color: Colors.amber)),
              ],
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xff293140))),
          ),
          child: Row(
            children: [
              if (_step > 0)
                IconButton(
                  tooltip: 'Înapoi',
                  onPressed: _busy
                      ? null
                      : () async {
                          await _storage.write(
                            key: 'setup_step_v3',
                            value: '${_step - 1}',
                          );
                          if (mounted) setState(() => _step--);
                        },
                  icon: const Icon(Icons.arrow_back),
                ),
              if (_step == 2 || _step == 3)
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _busy
                        ? null
                        : _step == 2 && !_ecrVerified
                        ? _status
                        : _next,
                    icon: Icon(
                      _step == 2 && !_ecrVerified
                          ? Icons.wifi_tethering
                          : Icons.arrow_forward,
                      size: 18,
                    ),
                    label: Text(
                      _busy
                          ? 'Se verifică…'
                          : _step == 2
                          ? (_ecrVerified ? 'Continuă la Viva' : 'Verifică ECR')
                          : (!_vivaEnabled
                                ? 'Configurează Viva mai târziu'
                                : 'Continuă la verificare'),
                    ),
                  ),
                ),
              if (_step == 0 || _step == 1 || _step == 4)
                const Expanded(
                  child: Text(
                    'Asocierea este păstrată securizat pe telefon.',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
