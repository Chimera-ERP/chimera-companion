import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'debug_panel.dart';
import 'local_server.dart';
import 'local_tls.dart';
import 'connectivity_client.dart';
import 'tls_provisioning.dart';
import 'device_credentials.dart';
import 'customer_display.dart';
import 'customer_display_bundle.dart';
import 'package:crypto/crypto.dart';
import 'erp_commands.dart';
import 'diagnostic_outbox.dart';
import 'security/device_identity.dart';
import 'security/offline_session.dart';
import 'security/external_payment.dart';
import 'security/daily_z.dart';
import 'security/sale_admission.dart';
import 'security/sale_lifecycle.dart';
import 'hardware/command_journal.dart';
import 'hardware/command_executor.dart';
import 'hardware/contracts.dart';
import 'hardware/connection.dart';
import 'hardware/fiscal_device.dart';
import 'hardware/tremol_adapter.dart';
import 'hardware/json_transport.dart';
import 'hardware/runtime.dart';
import 'hardware/viva_adapter.dart';
import 'hardware/viva_connection.dart';
import 'printing/production_print.dart';
import 'scale_service.dart';
import 'console/console_service.dart';

const companionOperations = [
  'status',
  'history',
  'customerDisplay',
  'operatorLogin',
  'operatorLogout',
  'drawerCountStart',
  'drawerCountEnd',
  'saleAuthorize',
  'salePaymentStart',
  'salePaymentReject',
  'saleAbandon',
  'saleExternalPaymentConfirm',
  'fiscalPolicy',
  'cashDeposit',
  'cashWithdraw',
  'nonFiscal',
  'fiscalReceipt',
  'xReport',
  'zReport',
  'payment',
  'paymentTest',
  'rawEcr',
];

/// Monitoring and command dispatch have the same lifetime as the local server.
class LocalBridge extends ChangeNotifier {
  LocalBridge({
    CommandJournal? journal,
    OfflineSession? security,
    this.paymentFactory,
    this.printerSend = sendPrinterBytes,
    FiscalDevice Function(Map<String, dynamic>)? deviceFactory,
  }) : _deviceFactory = deviceFactory ?? FiscalDevice.fromSettings {
    _journal = journal;
    _security = security;
  }
  final FiscalDevice Function(Map<String, dynamic>) _deviceFactory;
  final PrinterSend printerSend;
  bool _hasEcr(Map<String, dynamic>? settings) =>
      settings?['host'] is String &&
      (settings!['host'] as String).trim().isNotEmpty;
  FiscalDevice _configuredDevice(Map<String, dynamic> settings) {
    if (!_hasEcr(settings)) {
      throw StateError('Casa de marcat nu este configurată.');
    }
    final host = settings['host'], port = int.tryParse('${settings['port']}');
    final code = host is String && port != null
        ? _security?.loyaltyPaymentCode(host, port)
        : null;
    return _deviceFactory({...settings, 'loyaltyPaymentCode': code});
  }

  final PaymentTerminalAdapter Function(Map<String, dynamic>)? paymentFactory;
  final _executor = HardwareCommandExecutor();
  final _customerDisplay = CustomerDisplay();
  ScaleService? _scales;
  ScaleService get scales => _scales ??= ScaleService();
  ConsoleService? _console;
  ConsoleService get console => _console ??= ConsoleService();
  bool _scaleRestored = false;
  CustomerDisplayBundle? _displayBundle;
  Future<void>? _displaySync;
  String? _displayError;
  static const _storage = FlutterSecureStorage();
  CompanionServer? _server;
  OfflineSession? _security;
  CommandJournal? _journal;
  Timer? _timer;
  Timer? _connectivityTimer;
  Timer? _erpCommandsTimer;
  ErpCommands? _erpCommands;
  DiagnosticOutbox? _diagnostics;
  Future<void> Function(String, String)? _errorReporter;
  String? _lastHardwareError;
  Future<void>? _maintaining;
  LocalTls? _activeTls;
  String? _activeBundle;
  bool _tlsReloading = false;
  String tlsStatus = 'Certificatul nu a fost verificat';
  bool _checking = false, _closed = false, _executing = false;
  Future<void>? _publishing;
  bool _publishAgain = false;
  Future<void>? _starting;
  Future<void>? _refreshing;
  bool configurationOpen = false;
  int? get port => _server?.port;
  bool get busy => _executing || _tlsReloading;
  bool erpConnected = false, posActive = false;
  String location = 'Locație neasociată';
  String? companionId, locationId;
  DateTime? lastPublished, lastPosRequest;
  List<String> localUrls = [];
  List<Map<String, dynamic>> history = [];
  Map<String, Object?> ecr = {
    'state': 'unknown',
    'message': 'Se verifică',
    'name': 'Casă de marcat',
    'capabilities': <String>[],
  };
  Map<String, Object?> payment = {
    'state': 'disabled',
    'message': 'Opțional · neconfigurat',
    'name': 'Viva Terminal',
    'capabilities': <String>[],
  };
  Map<String, Object?>? activeCommand;
  Map<String, Object?> get snapshot => {
    'version': 1,
    'state': busy || configurationOpen
        ? 'busy'
        : port == null
        ? 'error'
        : 'ready',
    'ecr': ecr,
    'payment': payment,
    'localUrls': localUrls,
    if (activeCommand != null) 'activeCommand': activeCommand,
  };
  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<Map<String, dynamic>?> _read(String key) async {
    final source = await _storage.read(key: key);
    return source == null ? null : jsonDecode(source) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _erp(
    String path,
    Map<String, Object?> payload,
  ) async {
    final pairing = await currentDevicePairing();
    companionId = pairing['device_id'] as String?;
    locationId = pairing['location_id'] as String?;
    final base = Uri.parse(pairing['erp_url'] as String);
    if (base.scheme != 'https') throw StateError('ERP HTTPS required');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(base.resolve(path));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${pairing['token']}',
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw HttpException('Chimera ${response.statusCode}');
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);
  Future<void> _start() async {
    if (_server != null || _closed) return;
    final directory = await getApplicationSupportDirectory();
    final tlsDirectory = Directory('${directory.path}/local-tls');
    LocalTls tls;
    try {
      tls = await LocalTls.load(tlsDirectory);
    } on FormatException {
      // An expired managed certificate can be renewed before exposing the
      // listener. Manual/invalid setups still fail closed if no renewal exists.
      await ConnectivityClient(
        provisioning: TlsProvisioning(tlsDirectory),
      ).maintain();
      tls = await LocalTls.load(tlsDirectory);
    }
    _journal = CommandJournal(
      File('${directory.path}/hardware-commands.jsonl'),
    );
    history = await _journal!.recent();
    final pairing = await _read('erp_pairing_v1');
    if (pairing == null ||
        pairing['location_id'] is! String ||
        pairing['device_id'] is! String) {
      throw StateError('Chimera enrollment required');
    }
    final enrolledClaims =
        jsonDecode(
              utf8.decode(
                base64Url.decode(
                  base64Url.normalize(
                    (pairing['token'] as String).split('.')[1],
                  ),
                ),
              ),
            )
            as Map<String, dynamic>;
    final org = pairing['org'] ?? pairing['org_id'] ?? enrolledClaims['org'];
    if (org is! String) throw StateError('Organization required');
    _displayBundle = CustomerDisplayBundle(
      Directory(
        '${directory.path}/customer-displays/${sha256.convert(utf8.encode('$org:${pairing['location_id']}'))}',
      ),
      org: org,
      location: pairing['location_id'] as String,
    );
    await _displayBundle!.restore();
    await _customerDisplay.useBundle(_displayBundle!.directory);
    final identity = DeviceIdentity();
    final security = OfflineSession(
      file: File('${directory.path}/offline-trust.json'),
      org: org,
      location: pairing['location_id'],
      companion: pairing['device_id'],
      identity: identity,
    );
    await security.restore();
    _security = security;
    _diagnostics = DiagnosticOutbox(
      _storage,
      _erp,
      scope: '$org:${pairing['device_id']}',
    );
    _errorReporter = (code, detail) async {
      await _diagnostics?.add(code, detail);
      try {
        await _diagnostics?.flush();
      } catch (_) {}
    };
    reportCompanionError = _errorReporter;
    _erpCommands = ErpCommands(
      post: _erp,
      verify: security.verifyErp,
      sign: identity.sign,
      dispatch: (grant, payload) =>
          [
            'companionDiagnostics',
            'companionRefreshAuthorization',
          ].contains(grant['operations'].single)
          ? _runCompanionControl(grant)
          : run(
              (grant['operations'] as List).single as String,
              grant['commandId'] as String,
              payload,
              expectedEndpoint: grant['equipment'] as String,
              authorizationExpires: DateTime.fromMillisecondsSinceEpoch(
                (grant['exp'] as int) * 1000,
              ),
            ),
      recover: (grant, payload) async {
        if ([
          'companionDiagnostics',
          'companionRefreshAuthorization',
        ].contains(grant['operations'].single)) {
          return _runCompanionControl(grant, recover: true);
        }
        final settings = await _read('local_hardware_v1');
        if (settings == null) {
          return {
            'outcome': 'unknown',
            'message':
                'Configurație indisponibilă; comanda nu a fost retrimisă.',
          };
        }
        final recorded = await _journal!.lookup(
          id: grant['commandId'] as String,
          deviceId: _configuredDevice(settings).id,
          operation: (grant['operations'] as List).single as String,
          payload: payload,
        );
        return {
          'outcome': recorded?.outcome.name ?? 'unknown',
          'reference': recorded?.reference,
          'message':
              recorded?.message ??
              'Nu există confirmare locală. Comanda nu a fost retrimisă.',
        };
      },
    );
    try {
      await _erp('/api/devices/companion/offline/identity', {
        'public_jwk': await identity.publicKey(),
      });
      await security.updateTrust(
        await _erp('/api/devices/companion/offline/trust', {}),
      );
    } catch (_) {
      debugLog('Autorizarea locală folosește ultima configurație validată.');
    }
    final server = CompanionServer(
      console: console,
      runProductionPrint: runProductionPrint,
      runProductionLabel: runProductionLabel,
      security: security,
      onAuthorizationError: (reason) async {
        await _diagnostics?.add('authorization_rejected', reason);
        unawaited(_diagnostics?.flush().catchError((_) {}));
      },
      onFailure: (code, detail) async {
        await _diagnostics?.add(code, detail);
        unawaited(_diagnostics?.flush().catchError((_) {}));
      },
      runAuthorized: (operation, id, payload, expires) async {
        lastPosRequest = DateTime.now();
        return run(
          operation,
          id,
          payload,
          authorizationExpires: DateTime.fromMillisecondsSinceEpoch(expires),
        );
      },
      verify: (ticket) =>
          _erp('/api/devices/companion/verify', {'ticket': ticket}),
      run: (operation, id, payload) async {
        lastPosRequest = DateTime.now();
        return run(operation, id, payload);
      },
    );
    await server.start(
      securityContext: tls.context,
      allowedHosts: tls.allowedHosts,
    );
    _server = server;
    _activeTls = tls;
    final bundle = File('${directory.path}/local-tls/bundle.json');
    _activeBundle = await bundle.exists() ? await bundle.readAsString() : null;
    localUrls = [tls.origin.origin];
    if (Platform.isAndroid) {
      try {
        await const MethodChannel(
          'chimera/lifecycle',
        ).invokeMethod<bool>('start');
      } catch (_) {
        debugLog(
          'Serviciul de fundal nu a pornit; păstrează Companion deschis.',
        );
      }
    }
    debugLog('API local pornit · port ${server.port}');
    _timer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(refresh()),
    );
    _connectivityTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(maintainConnectivity()),
    );
    unawaited(maintainConnectivity());
    await refresh();
    _erpCommandsTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(pollErpCommands()),
    );
  }

  Future<void> pollErpCommands() async {
    if (_closed || configurationOpen || busy || _checking) return;
    try {
      try {
        await _diagnostics?.flush();
      } catch (_) {}
      await _erpCommands?.poll();
    } catch (_) {
      debugLog(
        'Comenzile ERP nu pot fi sincronizate; fără retrimitere hardware.',
      );
    }
  }

  Future<Map<String, Object?>> _companionDiagnostics() async {
    await refresh();
    final settings = await _read('local_hardware_v1');
    Map<String, dynamic>? active, pending;
    if (_hasEcr(settings)) {
      final suffix = CommandJournal.fingerprint(
        _configuredDevice(settings!).id,
        'operatorLogin',
        {},
      );
      active = await _read('operator_active_$suffix');
      pending = await _read('operator_transition_$suffix');
    }
    return {
      'outcome': 'succeeded',
      'message': 'Diagnostic Companion (fără execuție fiscală)',
      'diagnosticVersion': 1,
      'console': _console?.diagnostics ?? {'connected': false},
      'snapshot': snapshot,
      'operator': {
        for (final name in [
          'operatorId',
          'operatorName',
          'closed',
          'closingId',
        ])
          if (active?.containsKey(name) == true) name: active![name],
        'transitionPending': pending?['transition'] != null,
      },
      'recentCommands': (await _journal!.recent()).take(20).toList(),
      'diagnosticOverflow': await _diagnostics?.overflow() ?? 0,
    };
  }

  Future<Map<String, Object?>> _runCompanionControl(
    Map<String, dynamic> grant, {
    bool recover = false,
  }) async {
    final key = 'companion_control_${grant['commandId']}';
    final saved = await _read(key);
    if (saved != null) return saved;
    if (recover) {
      return {
        'outcome': 'unknown',
        'message': 'Diagnostic neconfirmat. Nu a fost retrimis.',
      };
    }
    if (grant['operations'].single == 'companionRefreshAuthorization') {
      await _security!.updateTrust(
        await _erp('/api/devices/companion/offline/trust', {}),
      );
    }
    final result = await _companionDiagnostics();
    await _write(key, Map<String, dynamic>.from(result));
    return result;
  }

  Future<void> maintainConnectivity() => _maintaining ??=
      _maintainConnectivity().whenComplete(() => _maintaining = null);
  Future<void> _maintainConnectivity() async {
    if (_closed || configurationOpen || busy) return;
    final directory = await getApplicationSupportDirectory();
    final tlsDirectory = Directory('${directory.path}/local-tls');
    final bundle = File('${tlsDirectory.path}/bundle.json');
    try {
      final expires = await ConnectivityClient(
        provisioning: TlsProvisioning(tlsDirectory),
      ).maintain();
      if (_closed) return;
      tlsStatus = expires == null
          ? 'Certificat administrat manual'
          : 'Valabil până la ${expires.toLocal()}';
      if (await bundle.exists()) {
        final content = await bundle.readAsString();
        if (content != _activeBundle && !busy && !configurationOpen) {
          final tls = await LocalTls.load(tlsDirectory);
          if (_closed || busy || configurationOpen) return;
          final server = _server;
          if (server != null) {
            _tlsReloading = true;
            _server = null;
            try {
              await server.close();
              if (_closed) return;
              await server.start(
                securityContext: tls.context,
                allowedHosts: tls.allowedHosts,
              );
              _activeTls = tls;
              _activeBundle = content;
              localUrls = [tls.origin.origin];
              debugLog(
                'Certificat HTTPS reîncărcat; comenzile financiare nu au fost repetate.',
              );
            } catch (error) {
              if (!_closed && _activeTls != null) {
                await server.start(
                  securityContext: _activeTls!.context,
                  allowedHosts: _activeTls!.allowedHosts,
                );
              }
              rethrow;
            } finally {
              if (!_closed) {
                _server = server.running ? server : null;
              } else {
                await server.close();
              }
              _tlsReloading = false;
            }
          }
        }
      }
    } catch (_) {
      tlsStatus =
          'Actualizarea HTTPS/DNS a eșuat; verifică certificatul și rețeaua.';
      try {
        final installed =
            jsonDecode(await bundle.readAsString()) as Map<String, dynamic>;
        final expires = DateTime.tryParse(
          installed['expiresAt'] as String? ?? '',
        );
        if (expires != null) tlsStatus += ' Expiră la ${expires.toLocal()}.';
      } catch (_) {
        /* No usable installed bundle to report. */
      }
      debugLog(tlsStatus);
    } finally {
      _changed();
    }
  }

  Future<void> _publish() {
    if (_publishing != null) {
      _publishAgain = true;
      return _publishing!;
    }
    return _publishing = _drainPublish().whenComplete(() => _publishing = null);
  }

  Future<void> _drainPublish() async {
    do {
      _publishAgain = false;
      await _publishLatest();
    } while (_publishAgain && !_closed);
  }

  Future<void> _publishLatest() async {
    try {
      final result = await _erp('/api/devices/companion/heartbeat', snapshot);
      if (_security != null) {
        final settings = await _read('local_hardware_v1');
        if (settings != null) {
          try {
            if (_hasEcr(settings)) {
              final ecr = _configuredDevice(settings);
              await _erp(
                '/api/devices/companion/management/equipment/register',
                {
                  'kind': 'ecr',
                  'name': ecr.name,
                  'host': ecr.connection.endpoint.host,
                  'port': ecr.connection.endpoint.port,
                  'payment_catalog': settings['paymentCatalog'] ?? [],
                },
              );
            }
            if (settings['vivaEnabled'] == 'true') {
              final viva = vivaEndpoint(
                settings['vivaHost'] as String? ?? '',
                settings['vivaPort'] as String? ?? '',
              );
              await _erp(
                '/api/devices/companion/management/equipment/register',
                {
                  'kind': 'payment',
                  'name': 'Viva Terminal',
                  'host': viva.host,
                  'port': viva.port,
                },
              );
            }
          } catch (_) {
            debugLog(
              'Echipamentul nu a putut fi înregistrat în ERP. Verifică asocierea existentă sau conexiunea; comenzile rămân protejate.',
            );
          }
        }
        // Optional printer registration reuses the existing heartbeat. No probe,
        // discovery or printer worker is started on ECR/Viva-only installations.
        final printerSettings = await _read('production_printer_v1');
        if (printerSettings != null) {
          try {
            final printer = PrinterConfig.fromJson(printerSettings);
            await _erp('/api/devices/companion/management/equipment/register', {
              'kind': 'printer',
              'name': printer.name,
              'host': printer.host,
              'port': printer.port,
            });
          } catch (_) {
            debugLog('Asocierea imprimantei necesită verificare în ERP.');
          }
        }
        await _security!.updateTrust(
          await _erp('/api/devices/companion/offline/trust', {}),
        );
      }
      if (result['location_id'] != locationId) {
        throw const FormatException('Location mismatch');
      }
      location = result['location_name'] as String? ?? 'Locație asociată';
      erpConnected = true;
      posActive = result['pos_recently_active'] == true;
      lastPublished = DateTime.now();
      // Media I/O never blocks basket frames, hardware commands or heartbeat.
      _displaySync ??= _syncDisplay().whenComplete(() => _displaySync = null);
    } catch (_) {
      erpConnected = false;
    }
    _changed();
  }

  Future<void> _syncDisplay() async {
    final bundle = _displayBundle;
    if (bundle == null) return;
    try {
      final response =
          await _erp('/api/devices/companion/customer-display/sync', {
            'bundleKey': bundle.key,
            'revision': bundle.revision,
            'errorCode': _displayError,
          });
      final manifest = response['manifest'];
      if (manifest == null) {
        _displayError = null;
        return;
      }
      final changed = await bundle.install(
        Map<String, dynamic>.from(manifest as Map),
        _downloadDisplay,
      );
      if (changed || _displayError == 'activation_failed') {
        try {
          await _customerDisplay.useBundle(bundle.directory);
        } catch (_) {
          _displayError = 'activation_failed';
          return;
        }
      }
      _displayError = null;
    } catch (error) {
      _displayError = error is FormatException
          ? 'invalid_bundle'
          : 'download_failed';
      debugLog(
        'Ecran client: actualizare nereușită; păstrăm ultima versiune offline.',
      );
    }
  }

  Future<List<int>> _downloadDisplay(String path, int limit) async {
    final pairing = await currentDevicePairing();
    final base = Uri.parse(pairing['erp_url'] as String);
    if (base.scheme != 'https') {
      throw const FormatException('ERP HTTPS required');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(
        base.resolve('/api/devices/companion/customer-display/$path'),
      );
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${pairing['token']}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200 || response.contentLength > limit) {
        throw const HttpException('Display download refused');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > limit) {
          throw const FormatException('Display download exceeds limit');
        }
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    if (_checking || _closed) return;
    if (busy || configurationOpen) {
      await _recordHardwareErrors();
      await _publish();
      return;
    }
    _checking = true;
    try {
      final settings = await _read('local_hardware_v1');
      if (!_hasEcr(settings)) {
        ecr = {
          'state': 'unconfigured',
          'message': 'Configurează casa de marcat',
          'name': 'Casă de marcat',
          'capabilities': <String>[],
        };
      } else {
        try {
          final device = _configuredDevice(settings!);
          final state = await device.readStatus();
          ecr = {
            'state': state.ready ? 'ready' : 'error',
            'message': state.description,
            'diagnostics': state.details,
            'name': device.name,
            'model': device.connection.model.name,
            'capabilities': device.capabilities,
          };
        } catch (error) {
          ecr = {
            ...ecr,
            'state': 'error',
            'message': error is TremolLanPasswordRequired
                ? error.toString()
                : 'Casa de marcat este indisponibilă: poate fi oprită sau inaccesibilă. Verifică alimentarea, conexiunea LAN și configurarea.',
          };
        }
      }
      payment = {
        'state': 'disabled',
        'message': 'Plățile cu cardul nu sunt configurate',
        'name': 'Viva Terminal',
        'capabilities': <String>[],
      };
      if (settings?['vivaEnabled'] == 'true') {
        try {
          final state = await checkVivaConnection(
            vivaEndpoint(
              settings!['vivaHost'] as String? ?? '',
              settings['vivaPort'] as String? ?? '',
            ),
            settings['vivaPin'] as String? ?? '',
          );
          payment = {
            'state': state.trusted ? 'ready' : 'error',
            'message': state.trusted
                ? 'Conexiune TLS verificată'
                : state.message,
            'name': 'Viva Terminal',
            'capabilities': ['payment', 'paymentTest'],
          };
        } catch (_) {
          payment = {
            'state': 'error',
            'message': 'Viva Terminal indisponibil',
            'name': 'Viva Terminal',
            'capabilities': <String>[],
          };
        }
      }
      await _recordHardwareErrors();
      await _publish();
    } finally {
      _checking = false;
      _changed();
    }
  }

  Future<void> _recordHardwareErrors() async {
    final signature =
        '${ecr['state'] == 'error' ? ecr['message'] : ''}|${payment['state'] == 'error' ? payment['message'] : ''}';
    if (signature == _lastHardwareError) return;
    _lastHardwareError = signature;
    if (ecr['state'] == 'error') {
      try {
        await _diagnostics?.add(
          'ecr_status_error',
          ecr['message'] as String? ?? 'ECR unavailable',
        );
      } catch (_) {}
    }
    if (payment['state'] == 'error') {
      try {
        await _diagnostics?.add(
          'payment_status_error',
          payment['message'] as String? ?? 'Payment terminal unavailable',
        );
      } catch (_) {}
    }
  }

  Future<Map<String, Object?>> runProductionPrint(
    String ticket,
    Map<String, dynamic> payload,
    String origin,
  ) async {
    final security = _security;
    final journal = _journal;
    if (security == null || journal == null) {
      throw const FormatException('Production print trust unavailable');
    }
    final job = ProductionPrintJob(payload);
    final grant = await security.verifyProductionPrint(ticket, payload, origin);
    return _executeProductionPrint(job, grant, security, journal, () async {
      await security.verifyProductionPrint(ticket, payload, origin);
    });
  }

  Future<Map<String, Object?>> runProductionLabel(
    Map<String, dynamic> body,
    String origin,
  ) async {
    final security = _security;
    final journal = _journal;
    if (security == null || journal == null) {
      throw const FormatException('Production label trust unavailable');
    }
    final payload = Map<String, dynamic>.from(body['payload']);
    final job = ProductionPrintJob(payload);
    final grant = await security.verifyProductionLabel(
      body['lease'],
      payload,
      body['message'],
      body['signature'],
      origin,
    );
    return _executeProductionPrint(job, grant, security, journal, () async {
      await security.verifyProductionLabel(
        body['lease'],
        payload,
        body['message'],
        body['signature'],
        origin,
      );
    });
  }

  Future<Map<String, Object?>> _executeProductionPrint(
    ProductionPrintJob job,
    Map<String, dynamic> grant,
    OfflineSession security,
    CommandJournal journal,
    Future<void> Function() authorize,
  ) async {
    final payload = job.payload;
    final saved = await _read('production_printer_v1');
    if (saved == null) throw const FormatException('Printer is not configured');
    final config = PrinterConfig.fromJson(saved);
    var admitted = false;
    try {
      final result =
          await ProductionPrinter(
            executor: _executor,
            journal: journal,
            send: printerSend,
          ).execute(
            config,
            job,
            audit: {
              'authorizedActor': grant['sub'],
              'authorizedDevice': grant['pos'],
              if (grant['kind'] == 'production-label-lease') ...{
                'labelLeaseId': grant['session_id'],
                'maxCommands': grant['labelScope']['max_commands'],
                'labelDocumentHash': CommandJournal.fingerprint(
                  config.id,
                  'provisional-label-document',
                  Map<String, dynamic>.from(payload)
                    ..remove('commandId')
                    ..remove('reprintOf')
                    ..remove('reprintReason'),
                ),
              },
            },
            authorize: () async {
              await authorize();
              final current = await _read('production_printer_v1');
              if (busy ||
                  configurationOpen ||
                  current == null ||
                  canonicalJson(current) != canonicalJson(saved) ||
                  !security.ownsEquipment(
                    'printer',
                    config.host,
                    config.port,
                  )) {
                throw const FormatException(
                  'Printer assignment or configuration changed',
                );
              }
              admitted = true;
              _executing = true;
              activeCommand = {'id': job.id, 'operation': job.operation};
              _changed();
            },
          );
      history = await journal.recent();
      _changed();
      return await security.result({
        ...result,
        'operatorId': grant['sub'],
        'deviceId': grant['pos'],
        'org': security.org,
        'location': security.location,
        if (grant['kind'] == 'production-label-lease') ...{
          'leaseId': grant['session_id'],
          'reportId': payload['reportId'],
        },
      }, hardwarePayloadHash(payload));
    } finally {
      if (admitted) {
        _executing = false;
        activeCommand = null;
        _changed();
      }
    }
  }

  Future<Map<String, Object?>> run(
    String operation,
    String id,
    Map<String, dynamic> payload, {
    String? expectedEndpoint,
    DateTime? authorizationExpires,
  }) async {
    if (operation == 'customerDisplay') {
      if (authorizationExpires == null ||
          !authorizationExpires.isAfter(DateTime.now())) {
        return {'outcome': 'rejected', 'message': 'Autorizare POS necesară.'};
      }
      final display = await _customerDisplay.update(payload);
      return {
        'outcome': 'succeeded',
        'message': 'Stare ecran client',
        'customerDisplay': display,
      };
    }
    if (['status', 'history'].contains(operation)) {
      return _runNow(operation, id, payload);
    }
    final settings = await _read('local_hardware_v1');
    if (settings == null) {
      return {'outcome': 'rejected', 'message': 'Dispozitive neconfigurate'};
    }
    if (!['payment', 'paymentTest'].contains(operation) && !_hasEcr(settings)) {
      return {
        'outcome': 'rejected',
        'message': 'Casa de marcat nu este configurată.',
      };
    }
    final equipment = ['payment', 'paymentTest'].contains(operation)
        ? 'viva:${settings['vivaHost']}:${settings['vivaPort']}'
        : _configuredDevice(settings).id;
    final configurationHash = CommandJournal.fingerprint(
      equipment,
      'configuration',
      settings,
    );
    return _executor.execute(
      equipment: equipment,
      id: id,
      operation: operation,
      payload: payload,
      dispatch: () async {
        if (authorizationExpires != null &&
            !authorizationExpires.isAfter(DateTime.now())) {
          return {
            'outcome': 'rejected',
            'message': 'Autorizarea comenzii a expirat în coadă.',
          };
        }
        final current = await _read('local_hardware_v1');
        if (current == null ||
            configurationHash !=
                CommandJournal.fingerprint(
                  equipment,
                  'configuration',
                  current,
                )) {
          return {
            'outcome': 'rejected',
            'message':
                'Configurația echipamentului s-a schimbat în timpul așteptării.',
          };
        }
        final paying = ['payment', 'paymentTest'].contains(operation);
        final endpoint = paying
            ? vivaEndpoint(
                current['vivaHost'] as String? ?? '',
                current['vivaPort'] as String? ?? '',
              )
            : _deviceFactory(current).connection.endpoint;
        if (expectedEndpoint != null &&
            expectedEndpoint != '${endpoint.host}:${endpoint.port}') {
          return {
            'outcome': 'rejected',
            'message': 'Echipamentul ERP diferă de configurația locală.',
          };
        }
        if (_security != null &&
            !_security!.ownsEquipment(
              paying ? 'payment' : 'ecr',
              endpoint.host,
              endpoint.port,
            )) {
          return {
            'outcome': 'rejected',
            'message':
                'Asociază explicit echipamentul cu acest Companion în ERP.',
          };
        }
        return _runNow(operation, id, payload);
      },
    );
  }

  Future<Map<String, Object?>> _runNow(
    String operation,
    String id,
    Map<String, dynamic> payload,
  ) async {
    if (operation == 'status') {
      if (!_scaleRestored) {
        _scaleRestored = true;
        unawaited(scales.restore());
      }
      if (payload['scope'] == 'scale') {
        return {
          'outcome': 'succeeded',
          'companionId': companionId,
          'locationId': locationId,
          'message': 'Cântar',
          'scale': await scales.snapshot(),
        };
      }
      await refresh();
      return {
        ...snapshot,
        'outcome': 'succeeded',
        'service': 'chimera-companion',
        'companionId': companionId,
        'locationId': locationId,
        'ecrReady': ecr['state'] == 'ready' && !_executing,
        'capabilities': ecr['capabilities'],
        'paymentStartProofVersion': 1,
        'saleAdmissionLifecycleVersion': 1,
        'commandRecoveryVersion': 1,
        'offlineShiftCloseVersion': 1,
        'customerDisplayVersion': 1,
        'customerDisplayStreamVersion': 1,
        'customerDisplay': await _customerDisplay.status(),
        'message': ecr['message'],
      };
    }
    if (operation == 'history') {
      return {'commands': await _journal!.recent(), 'message': 'Jurnal local'};
    }
    if (!companionOperations.contains(operation)) {
      throw ArgumentError('Unknown operation');
    }
    if (payload.containsKey('recoveryOnly') &&
        (payload['recoveryOnly'] != true ||
            ![
              'fiscalReceipt',
              'payment',
              'paymentTest',
              'xReport',
              'zReport',
              'nonFiscal',
              'cashDeposit',
              'cashWithdraw',
            ].contains(operation))) {
      throw ArgumentError(
        'Read-only recovery is not supported for this operation',
      );
    }
    // A background read must not turn a retry of a confirmed command into a
    // rejection: wait for the read, then let the journal return its result.
    if (_checking) await _refreshing;
    if (busy || configurationOpen) {
      return {
        'outcome': payload['recoveryOnly'] == true || activeCommand?['id'] == id
            ? 'unknown'
            : 'rejected',
        'message': 'Companion ocupat. Reîncearcă după verificare.',
      };
    }
    _executing = true;
    activeCommand = {'id': id, 'operation': operation};
    _changed();
    unawaited(_publish());
    try {
      if (operation == 'zReport' && payload['confirmCloseDay'] != true) {
        throw ArgumentError(
          'Explicit fiscal day closure confirmation required',
        );
      }
      final settings = await _read('local_hardware_v1');
      if (settings == null) {
        return {
          'outcome': payload['recoveryOnly'] == true ? 'unknown' : 'rejected',
          'message': 'Dispozitive neconfigurate',
        };
      }
      final journal = _journal;
      if (journal == null) {
        return {'outcome': 'rejected', 'message': 'Jurnal indisponibil'};
      }
      final drawerLock = await _read('cash_drawer_count_v1');
      if (operation == 'drawerCountStart' || operation == 'drawerCountEnd') {
        final shift = payload['shiftId'];
        if (shift is! String ||
            !RegExp(r'^shift_[a-z0-9]+$').hasMatch(shift) ||
            payload['operatorId'] is! String) {
          return {
            'outcome': 'rejected',
            'message': 'Tură verificată necesară.',
          };
        }
        if (drawerLock != null &&
            (drawerLock['shiftId'] != shift ||
                drawerLock['operatorId'] != payload['operatorId'])) {
          return {
            'outcome': 'rejected',
            'message': 'Alt operator numără sertarul.',
          };
        }
        if (operation == 'drawerCountStart') {
          final deviceId = _configuredDevice(settings).id;
          final settled = await journal.confirmedReceiptIds(deviceId);
          for (final entry in (await _storage.readAll()).entries.where(
            (e) => e.key.startsWith('sale_admission_'),
          )) {
            final admission = jsonDecode(entry.value);
            if (admission is! Map || admission['saleId'] is! String) {
              throw const FormatException('Invalid persisted sale admission');
            }
            if (admission['equipmentId'] != null &&
                admission['equipmentId'] != deviceId) {
              continue;
            }
            if (admission['lifecycleVersion'] == 1 &&
                SaleLifecycle.restore(
                  Map<String, dynamic>.from(admission),
                ).abandoned) {
              continue;
            }
            if (!settled.contains(admission['saleId'])) {
              return {
                'outcome': 'rejected',
                'message':
                    'Există o vânzare autorizată nefinalizată. Recuperează plata și bonul înainte de numărare.',
              };
            }
          }
          if (await journal.hasUnresolvedDrawerEffects(
            _configuredDevice(settings).id,
          )) {
            return {
              'outcome': 'rejected',
              'message':
                  'O vânzare sau o mișcare de numerar are rezultat neconfirmat. Verifică jurnalul înainte de numărare.',
            };
          }
          await _storage.write(
            key: 'cash_drawer_count_v1',
            value: jsonEncode({
              'shiftId': shift,
              'operatorId': payload['operatorId'],
            }),
          );
        } else {
          await _storage.delete(key: 'cash_drawer_count_v1');
        }
        return {
          'outcome': 'succeeded',
          'message': operation == 'drawerCountStart'
              ? 'Sertar rezervat pentru numărare.'
              : 'Sertar eliberat.',
        };
      }
      final device = operation == 'payment' || operation == 'paymentTest'
          ? null
          : _configuredDevice(settings);
      if (operation == 'fiscalPolicy') {
        if (_security == null ||
            payload['operatorId'] is! String ||
            payload['posId'] is! String) {
          throw const FormatException(
            'Verified operator required for fiscal policy',
          );
        }
        final state = await device!.readStatus();
        final stateKey =
            'daily_z_${CommandJournal.fingerprint(device.id, 'dailyZ', {})}';
        final clock = DailyZPolicy(await _read(stateKey));
        final decision = clock.evaluate(
          payload['checkoutPolicy'] is Map ? payload['checkoutPolicy'] : null,
          DateTime.now().toUtc(),
          hardwareNonZero: state.ready
              ? state.details['dailyReportNonZero'] as bool?
              : null,
        );
        await _write(stateKey, clock.toJson());
        return {
          'outcome': 'succeeded',
          'fiscalPolicy': decision,
          'message': state.description,
        };
      }
      if (operation == 'saleExternalPaymentConfirm') {
        if (_security == null ||
            payload['saleId'] is! String ||
            payload['amountMinor'] is! int ||
            payload['currency'] is! String ||
            payload['confirmed'] != true ||
            payload['checkoutPolicy'] is! Map ||
            payload['checkoutPolicy']['card_mode'] != 'external') {
          throw const FormatException(
            'Signed external-card policy and explicit confirmation required',
          );
        }
        final admissionKey =
            'sale_admission_${CommandJournal.fingerprint(device!.id, 'saleAuthorize', {'id': payload['saleId']})}';
        final admission = await _read(admissionKey);
        if (admission == null ||
            admission['lifecycleVersion'] != 1 ||
            admission['paymentMethod'] != 'card' ||
            admission['org'] != _security!.org ||
            admission['location'] != locationId ||
            admission['receiptCompanion'] != companionId ||
            admission['equipmentId'] != device.id ||
            admission['operatorId'] != payload['operatorId'] ||
            admission['posId'] != payload['posId']) {
          throw const FormatException('Matching external-card sale required');
        }
        final confirmed = SaleLifecycle.restore(admission)
            .confirmExternal(
              amountMinor: payload['amountMinor'],
              currency: payload['currency'],
            )
            .toJson();
        await _write(admissionKey, confirmed);
        return {
          'outcome': 'succeeded',
          'saleAdmission': confirmed,
          'message':
              'Plată confirmată de operator; nu este dovadă bancară electronică.',
        };
      }
      if (operation == 'saleAbandon') {
        if (_security == null || payload['saleId'] is! String) {
          throw const FormatException('Verified sale identity required');
        }
        final admissionKey =
            'sale_admission_${CommandJournal.fingerprint(device!.id, 'saleAuthorize', {'id': payload['saleId']})}';
        final admission = await _read(admissionKey);
        if (admission == null ||
            admission['lifecycleVersion'] != 1 ||
            admission['org'] != _security!.org ||
            admission['location'] != locationId ||
            admission['receiptCompanion'] != companionId ||
            admission['equipmentId'] != device.id ||
            admission['operatorId'] != payload['operatorId'] ||
            admission['posId'] != payload['posId']) {
          throw const FormatException(
            'Matching versioned sale identity required',
          );
        }
        if (await journal.containsCommandId(payload['saleId']) &&
            !(['cash', 'loyalty'].contains(admission['paymentMethod']) &&
                ['admitted', 'abandoned'].contains(admission['phase']) &&
                await journal.hasRejectedReceipt(
                  payload['saleId'],
                  device.id,
                ))) {
          return {
            'outcome': 'rejected',
            'message':
                'Bonul are deja o comandă în jurnal. Recuperează rezultatul; nu anula vânzarea.',
          };
        }
        final cancelled = SaleLifecycle.restore(admission).abandon().toJson();
        await _write(admissionKey, cancelled);
        return {
          'outcome': 'succeeded',
          'saleAdmission': cancelled,
          'message': 'Vânzarea neplătită a fost anulată.',
        };
      }
      if (operation == 'salePaymentReject') {
        if (_security == null ||
            payload['saleId'] is! String ||
            payload['paymentRejectionProof'] is! Map) {
          throw const FormatException('Signed terminal rejection required');
        }
        final admissionKey =
            'sale_admission_${CommandJournal.fingerprint(device!.id, 'saleAuthorize', {'id': payload['saleId']})}';
        final admission = await _read(admissionKey);
        if (admission == null ||
            admission['lifecycleVersion'] != 1 ||
            admission['org'] != _security!.org ||
            admission['location'] != locationId ||
            admission['receiptCompanion'] != companionId ||
            admission['equipmentId'] != device.id ||
            admission['operatorId'] != payload['operatorId'] ||
            admission['posId'] != payload['posId']) {
          throw const FormatException('Matching sale identity required');
        }
        final proof = Map<String, dynamic>.from(
          payload['paymentRejectionProof'],
        );
        if (admission['phase'] == 'abandoned' &&
            jsonEncode(admission['paymentRejectionProof']) ==
                jsonEncode(proof)) {
          return {
            'outcome': 'succeeded',
            'saleAdmission': admission,
            'message': 'Refuzul plății a fost înregistrat anterior.',
          };
        }
        if (await journal.containsCommandId(payload['saleId'])) {
          throw StateError(
            'Fiscal command already exists; recover its original result',
          );
        }
        _security!.verifyRecordedPaymentRejection(proof, admission);
        final cancelled = SaleLifecycle.restore(
          admission,
        ).rejectPayment().toJson()..['paymentRejectionProof'] = proof;
        await _write(admissionKey, cancelled);
        return {
          'outcome': 'succeeded',
          'saleAdmission': cancelled,
          'message':
              'Refuzul terminalului înregistrat; vânzarea nu a fost fiscalizată.',
        };
      }
      if (operation == 'salePaymentStart') {
        if (_security == null ||
            companionId == null ||
            payload['saleId'] is! String ||
            payload['paymentCompanion'] is! String ||
            !_security!.trustedPaymentCompanion(payload['paymentCompanion'])) {
          throw const FormatException('Trusted payment Companion required');
        }
        final admissionKey =
            'sale_admission_${CommandJournal.fingerprint(device!.id, 'saleAuthorize', {'id': payload['saleId']})}';
        final admission = await _read(admissionKey);
        if (admission == null ||
            admission['lifecycleVersion'] != 1 ||
            admission['operatorId'] != payload['operatorId'] ||
            admission['posId'] != payload['posId'] ||
            admission['org'] != _security!.org ||
            admission['location'] != locationId ||
            admission['receiptCompanion'] != companionId ||
            admission['equipmentId'] != device.id ||
            admission['expiresAt'] is! int ||
            admission['expiresAt'] <= DateTime.now().millisecondsSinceEpoch ||
            payload['amountMinor'] is! int ||
            payload['currency'] is! String) {
          throw const FormatException(
            'Matching versioned sale admission required',
          );
        }
        if (drawerLock != null) {
          return {
            'outcome': 'rejected',
            'message': 'Sertarul este în numărare.',
          };
        }
        if (admission['phase'] != 'payment_started' &&
            await journal.hasUnresolvedDrawerEffects(device.id)) {
          return {
            'outcome': 'rejected',
            'message':
                'Există operații neconfirmate pe casă. Recuperează rezultatul înainte de o plată nouă.',
          };
        }
        final state = SaleLifecycle.restore(admission).beginPayment(
          commandId: id,
          companion: payload['paymentCompanion'],
          amountMinor: payload['amountMinor'],
          currency: payload['currency'],
        );
        // Persist the possibly-started phase before returning a signature that
        // the terminal can use. Response loss must never restore unpaid state.
        await _write(admissionKey, state.toJson());
        return {
          'outcome': 'succeeded',
          'paymentAdmission': state.toJson(),
          'message': 'Începerea plății autorizată.',
        };
      }
      if (operation == 'saleAuthorize') {
        if (_security == null ||
            companionId == null ||
            locationId == null ||
            payload['operatorId'] is! String ||
            payload['posId'] is! String) {
          return {
            'outcome': 'rejected',
            'message':
                'Înrolare și operator verificat necesare pentru autorizarea vânzării.',
          };
        }
        if (drawerLock != null) {
          return {
            'outcome': 'rejected',
            'message': 'Sertarul este în numărare.',
          };
        }
        if (payload['receiptJson'] is! String ||
            (payload['receiptJson'] as String).length > 100000 ||
            payload['saleId'] != id ||
            payload['authorizationExpires'] is! int) {
          throw const FormatException('Invalid sale admission');
        }
        if (payload['authorizationExpires'] <=
            DateTime.now().millisecondsSinceEpoch) {
          return {
            'outcome': 'rejected',
            'message': 'Autorizarea operatorului a expirat.',
          };
        }
        final facts = saleFacts(
          Map<String, dynamic>.from(jsonDecode(payload['receiptJson'])),
        );
        if (facts['documentMode'] == 'nonfiscal' &&
            (payload['checkoutPolicy'] is! Map ||
                payload['checkoutPolicy']['allow_nonfiscal_sales'] != true)) {
          return {
            'outcome': 'rejected',
            'message': 'Politica ERP nu permite documente nefiscale.',
          };
        }
        if (facts['settlementVersion'] == 2 &&
            (facts['payments'] as List).any((p) => p['method'] == 'loyalty')) {
          final source = Map<String, dynamic>.from(
            jsonDecode(payload['receiptJson']),
          );
          if (source['fidelityAuthorization'] is! String) {
            throw const FormatException('Customer coins approval required');
          }
          _security!.verifyFidelity(source['fidelityAuthorization'], id, {
            ...source,
            'posId': payload['posId'],
            'operatorId': payload['operatorId'],
          });
        }
        final hash = saleFactsHash(facts);
        final admissionKey =
            'sale_admission_${CommandJournal.fingerprint(device!.id, 'saleAuthorize', {'id': id})}';
        final existing = await _read(admissionKey);
        if (existing != null) {
          if (existing['lifecycleVersion'] == 1 &&
              SaleLifecycle.restore(existing).abandoned) {
            return {
              'outcome': 'rejected',
              'message':
                  'Autorizarea vânzării a fost anulată. Folosește o vânzare nouă.',
            };
          }
          if (existing['receiptHash'] != hash ||
              existing['operatorId'] != payload['operatorId'] ||
              existing['posId'] != payload['posId']) {
            throw const FormatException(
              'Sale admission identity or payload changed',
            );
          }
          if (existing['expiresAt'] <= DateTime.now().millisecondsSinceEpoch) {
            return {
              'outcome': 'rejected',
              'message': 'Autorizarea vânzării a expirat.',
            };
          }
          return {
            'outcome': 'succeeded',
            'saleAdmission': existing,
            'message': 'Vânzare autorizată anterior.',
          };
        }
        if (await journal.containsCommandId(id)) {
          return {
            'outcome': 'rejected',
            'message':
                'Identificatorul vânzării există deja în jurnal. Recuperează operația originală; nu începe o plată nouă.',
          };
        }
        if (!await device.operatorReady(payload, _read)) {
          return {
            'outcome': 'rejected',
            'message': device.operatorReadinessMessage,
          };
        }
        if (facts['cui'] != null &&
            !device.capabilities.contains('buyerTaxId')) {
          return {
            'outcome': 'rejected',
            'message': 'Modelul nu permite CUI fiscal.',
          };
        }
        final state = await device.readStatus();
        if (!state.ready) {
          return {'outcome': 'rejected', 'message': state.description};
        }
        final stateKey =
            'daily_z_${CommandJournal.fingerprint(device.id, 'dailyZ', {})}';
        final clock = DailyZPolicy(await _read(stateKey)),
            now = DateTime.now().toUtc();
        final decision = clock.evaluate(
          payload['checkoutPolicy'] is Map ? payload['checkoutPolicy'] : null,
          now,
          hardwareNonZero: state.details['dailyReportNonZero'] as bool?,
        );
        await _write(stateKey, clock.toJson());
        if (decision['blocked'] == true) {
          return {
            'outcome': 'rejected',
            'message': decision['uncertain'] == true
                ? 'Starea fiscală trebuie verificată înainte de vânzare.'
                : 'Termenul Z este depășit. Emite raportul Z înainte de o vânzare nouă.',
            'fiscalPolicy': decision,
          };
        }
        final admission = {
          'org': _security?.org,
          'location': locationId,
          'saleId': id,
          'receiptHash': hash,
          'amountMinor': facts['paymentMethod'] == 'card'
              ? receiptCardAmount(facts)
              : facts['totalMinor'],
          'currency': facts['currency'],
          'operatorId': payload['operatorId'],
          'posId': payload['posId'],
          'receiptCompanion': companionId,
          'startedAt': now.toIso8601String(),
          'expiresAt': payload['authorizationExpires'],
        };
        admission['equipmentId'] = device.id;
        admission['paymentMethod'] = facts['paymentMethod'];
        final issued = SaleLifecycle.issue(
          admission,
          requestedVersion: payload['lifecycleVersion'],
        );
        await _write(admissionKey, issued);
        return {
          'outcome': 'succeeded',
          'saleAdmission': issued,
          'fiscalPolicy': decision,
          'message': 'Vânzare autorizată.',
        };
      }
      // Recover a durable result before live preflight reads. A changed ECR
      // operator or unreachable peripheral must not hide a completed command.
      // Operator changes have their own recoverable multi-phase journal.
      if (device != null &&
          !['operatorLogin', 'operatorLogout'].contains(operation)) {
        var recorded = await journal.lookup(
          id: id,
          deviceId: device.id,
          operation: operation,
          payload: Map<String, dynamic>.from(payload)..remove('checkoutPolicy'),
        );
        if(recorded?.outcome==CommandOutcome.unknown&&operation=='fiscalReceipt'){
          final business=Map<String,dynamic>.from(payload)..remove('checkoutPolicy');
          final hash=CommandJournal.fingerprint(device.id,operation,business);
          final evidence=await _read('receipt_${CommandJournal.fingerprint(device.id,id,{})}_$hash');
          if(evidence?['closed']==true || evidence?['closeAttempted']==true){
            recorded=await journal.execute(id:id,deviceId:device.id,operation:operation,payload:business,recoveryOnly:true,
              reconcile:()=>device.reconcileReceipt(id,evidence),
              dispatch:() async=>throw StateError('Recovery cannot print'));
          }
        }
        if (recorded != null) {
          return {
            'outcome': recorded.outcome.name,
            'journalFound': true,
            'reference': recorded.reference,
            ...recorded.fiscalIdentity,
            'message': recorded.message,
          };
        }
      }
      if (device != null && payload['recoveryOnly'] == true) {
        return {
          'outcome': 'unknown',
          'message':
              'Rezultatul comenzii nu există în jurnal. Recuperarea nu execută o comandă nouă.',
        };
      }
      if (drawerLock != null &&
          [
            'fiscalReceipt',
            'payment',
            'paymentTest',
            'cashDeposit',
            'cashWithdraw',
          ].contains(operation)) {
        return {
          'outcome': 'rejected',
          'message': 'Sertarul este în numărare. Așteaptă închiderea turei.',
        };
      }
      if (operation == 'operatorLogin' || operation == 'operatorLogout') {
        return await device!.setOperator(
          commandId: id,
          identity: payload,
          ending: operation == 'operatorLogout',
          journal: journal,
          read: _read,
          write: (key, value) =>
              _storage.write(key: key, value: jsonEncode(value)),
        );
      }
      if (operation == 'rawEcr') {
        if (device!.connection.model == FiscalModel.datecsDp25) {
          return {
            'outcome': 'rejected',
            'message': 'Consola raw disponibilă momentan pentru Tremol.',
          };
        }
        HardwareResult? rawResponse;
        final result = await journal.execute(
          id: id,
          deviceId: device.id,
          operation: operation,
          payload: payload,
          dispatch: () async {
            rawResponse = await TremolAdapter(device.connection).rawCommand(
              payload['command'] as int,
              (payload['data'] as List).cast<int>(),
            );
            // Raw responses can contain programmed passwords. Keep them only
            // in the local console, never in persistent/shared command history.
            return HardwareResult(
              rawResponse!.outcome,
              message:
                  'Comandă service ${payload['command']}; răspuns disponibil numai în consola locală.',
            );
          },
        );
        return {
          'outcome': result.outcome.name,
          'message': rawResponse?.message ?? result.message,
        };
      }
      List<String>? lines;
      if (operation == 'nonFiscal') {
        if (payload['lines'] is! List ||
            (payload['lines'] as List).any((e) => e is! String)) {
          throw ArgumentError('Invalid lines');
        }
        lines = (payload['lines'] as List).cast<String>();
        validateNonFiscalLines(lines);
      }
      FiscalReceipt? receipt;
      Map<String, dynamic>? receiptAdmission;
      CashMovementRequest? movement;
      if (['cashDeposit', 'cashWithdraw'].contains(operation)) {
        if (await journal.hasUnresolvedDrawerEffects(device!.id)) {
          return {
            'outcome': 'rejected',
            'message':
                'Există o operație de numerar sau un bon neconfirmat. Verifică rezultatul înainte de o mișcare nouă.',
          };
        }
        if (payload['amountMinor'] is! int ||
            payload['reason'] is! String ||
            payload['currency'] != 'RON') {
          throw ArgumentError('Invalid cash movement');
        }
        if (!await device.operatorReady(payload, _read)) {
          return {
            'outcome': 'rejected',
            'message': device.operatorReadinessMessage,
          };
        }
        movement = CashMovementRequest(
          commandId: id,
          amountMinor: payload['amountMinor'],
          withdrawal: operation == 'cashWithdraw',
          reason: payload['reason'],
        );
      }
      if (operation == 'fiscalReceipt') {
        if (payload['documentMode'] == 'nonfiscal' &&
            (payload['checkoutPolicy'] is! Map ||
                payload['checkoutPolicy']['allow_nonfiscal_sales'] != true)) {
          throw const FormatException('ERP does not permit non fiscal sales');
        }
        if (payload['settlementVersion'] == 2 &&
            (payload['payments'] as List).any(
              (p) => p['method'] == 'loyalty',
            )) {
          if (payload['fidelityAuthorization'] is! String) {
            throw const FormatException('Coins approval required');
          }
          _security!.verifyFidelity(
            payload['fidelityAuthorization'],
            id,
            payload,
          );
        }
        if (_security == null || payload['saleAuthorization'] is! Map) {
          throw const FormatException(
            'Sale authorization required before receipt',
          );
        }
        receiptAdmission = _security!.verifySaleAuthorization(
          Map<String, dynamic>.from(payload['saleAuthorization']),
          payload,
          fiscalReceipt: true,
        );
        if (receiptAdmission['lifecycleVersion'] == 1) {
          final admissionKey =
              'sale_admission_${CommandJournal.fingerprint(device!.id, 'saleAuthorize', {'id': payload['saleId']})}';
          final stored = await _read(admissionKey);
          if (stored == null ||
              stored['receiptHash'] != receiptAdmission['receiptHash']) {
            throw const FormatException('Sale admission missing or mismatched');
          }
          SaleLifecycle.restore(stored).requireReceiptState(
            paymentMethod: payload['paymentMethod'] as String,
            external: payload['externalPaymentConfirmation'] != null,
            paymentCommandId: payload['paymentCommandId'] as String?,
          );
        }
        if (!await device!.operatorReady(payload, _read)) {
          return {
            'outcome': 'rejected',
            'message':
                'Numele operatorului ECR nu corespunde operatorului POS. Reautentifică operatorul și rezolvă sincronizarea înainte de bon.',
          };
        }
        receipt = await _receipt(id, payload, settings, journal);
      }
      if (operation == 'paymentTest' &&
          (payload['amountMinor'] != 500 ||
              payload['currency'] != 'RON' ||
              payload.keys.any(
                (key) =>
                    !['amountMinor', 'currency', 'recoveryOnly'].contains(key),
              ))) {
        throw ArgumentError('Invalid payment test');
      }
      PaymentRequest? paymentRequest;
      if (operation == 'payment' || operation == 'paymentTest') {
        if (operation == 'payment' &&
            (payload['saleId'] is! String ||
                payload['saleId'] != payload['receiptCommandId'] ||
                payload['receiptCompanionId'] is! String ||
                _security == null ||
                !_security!.receiptCompanionExists(
                  payload['receiptCompanionId'] as String,
                ))) {
          throw const FormatException(
            'Payment must be bound to an authorized sale and receipt Companion',
          );
        }
        if (payload['amountMinor'] is! int ||
            payload['currency'] != 'RON' ||
            (payload['amountMinor'] as int) <= 0 ||
            (payload['amountMinor'] as int) > 99999999) {
          throw ArgumentError('Invalid payment');
        }
        paymentRequest = PaymentRequest(
          commandId: id,
          amountMinor: payload['amountMinor'] as int,
          currency: 'RON',
        );
      }
      HardwareResult result;
      Map<String, Object?>? recordedPaymentRejection;
      if (paymentRequest != null) {
        if (settings['vivaEnabled'] != 'true' &&
            payload['recoveryOnly'] != true) {
          return {'outcome': 'rejected', 'message': 'Viva dezactivat'};
        }
        final endpoint = vivaEndpoint(
          settings['vivaHost'] as String? ?? '',
          settings['vivaPort'] as String? ?? '',
        );
        final adapter =
            paymentFactory?.call(settings) ??
            VivaAdapter(
              PinnedTerminalTransport(
                endpoint,
                settings['vivaPin'] as String? ?? '',
              ),
            );
        if (payload['recoveryOnly'] == true) {
          final recorded = await HardwareRuntime(journal).payment(
            '${endpoint.host}:${endpoint.port}', adapter, paymentRequest,
            recoveryOnly: true,
            binding: {
              if (operation == 'payment') ...{
                'saleId': payload['saleId'],
                'receiptCommandId': payload['receiptCommandId'],
                'receiptCompanionId': payload['receiptCompanionId'],
              },
            },
          );
          return {
            'outcome': recorded.outcome.name,
            'journalFound': await journal.containsCommandId(id),
            'reference': recorded.reference,
            'message': recorded.message,
            if (operation == 'payment' &&
                recorded.outcome == CommandOutcome.rejected &&
                await journal.hasRecordedPaymentRejection(
                  id: id,
                  deviceId: '${endpoint.host}:${endpoint.port}',
                  payload: {
                    'vendor': adapter.vendor,
                    'amountMinor': payload['amountMinor'],
                    'currency': payload['currency'],
                    'saleId': payload['saleId'],
                    'receiptCommandId': payload['receiptCommandId'],
                    'receiptCompanionId': payload['receiptCompanionId'],
                  },
                ))
              'paymentRejection': {
                'org': _security!.org,
                'location': locationId,
                'saleId': payload['saleId'],
                'paymentCommandId': id,
                'receiptCompanion': payload['receiptCompanionId'],
                'amountMinor': payload['amountMinor'],
                'currency': payload['currency'],
                'outcome': 'rejected',
                'source': 'terminal_journal',
              },
            if (operation == 'payment' &&
                recorded.outcome == CommandOutcome.succeeded &&
                recorded.reference?.isNotEmpty == true)
              ...await _security!.paymentEvidence(
                id,
                payload,
                recorded.reference!,
              ),
          };
        }
        result = await HardwareRuntime(journal).payment(
          '${endpoint.host}:${endpoint.port}',
          adapter,
          paymentRequest,
          recoveryOnly: payload['recoveryOnly'] == true,
          preflight: operation == 'payment'
              ? () async {
                  if (payload['recoveryOnly'] == true) {
                    throw const FormatException(
                      'No recorded payment; recovery never starts a new payment',
                    );
                  }
                  if (payload['saleAuthorization'] is! Map) {
                    throw const FormatException(
                      'Sale authorization required before payment',
                    );
                  }
                  final admission = _security!.verifySaleAuthorization(
                    Map<String, dynamic>.from(payload['saleAuthorization']),
                    payload,
                    fiscalReceipt: false,
                  );
                  if (admission['lifecycleVersion'] == 1) {
                    if (payload['paymentAuthorization'] is! Map) {
                      throw const FormatException(
                        'Payment-start authorization required',
                      );
                    }
                    _security!.verifyPaymentStart(
                      Map<String, dynamic>.from(
                        payload['paymentAuthorization'],
                      ),
                      payload,
                      id,
                      admission['receiptHash'],
                    );
                  }
                }
              : null,
          binding: operation == 'payment'
              ? {
                  'saleId': payload['saleId'],
                  'receiptCommandId': payload['receiptCommandId'],
                  'receiptCompanionId': payload['receiptCompanionId'],
                }
              : const {},
        );
        if (operation == 'payment' &&
            result.outcome == CommandOutcome.rejected &&
            await journal.hasRecordedPaymentRejection(
              id: id,
              deviceId: '${endpoint.host}:${endpoint.port}',
              payload: {
                'vendor': adapter.vendor,
                'amountMinor': payload['amountMinor'],
                'currency': payload['currency'],
                'saleId': payload['saleId'],
                'receiptCommandId': payload['receiptCommandId'],
                'receiptCompanionId': payload['receiptCompanionId'],
              },
            )) {
          recordedPaymentRejection = {
            'org': _security!.org,
            'location': locationId,
            'saleId': payload['saleId'],
            'paymentCommandId': id,
            'receiptCompanion': payload['receiptCompanionId'],
            'amountMinor': payload['amountMinor'],
            'currency': payload['currency'],
            'outcome': 'rejected',
            'source': 'terminal_journal',
          };
        }
      } else {
        if(operation=='fiscalReceipt'){
          final hash=CommandJournal.fingerprint(device!.id,operation,Map<String,dynamic>.from(payload)..remove('checkoutPolicy'));
          final evidenceKey='receipt_${CommandJournal.fingerprint(device.id,id,{})}_$hash';
          device.receiptCheckpoint=(evidence)=>_write(evidenceKey,evidence);
        }
        result = await journal.execute(
          id: id,
          deviceId: device!.id,
          operation: operation,
          payload: Map<String, dynamic>.from(payload)..remove('checkoutPolicy'),
          dispatch: () => switch (operation) {
            'nonFiscal' => device.nonFiscal(lines!),
            'fiscalReceipt' => device.receipt(receipt!),
            'cashDeposit' || 'cashWithdraw' => device.cashMovement(movement!),
            'xReport' => device.report(closeDay: false),
            'zReport' => device.report(closeDay: true),
            _ => throw ArgumentError('Unsupported operation'),
          },
        );
        if (operation == 'fiscalReceipt' &&
            payload['documentMode'] != 'nonfiscal' &&
            result.outcome != CommandOutcome.rejected) {
          final stateKey =
              'daily_z_${CommandJournal.fingerprint(device.id, 'dailyZ', {})}';
          final clock = DailyZPolicy(await _read(stateKey)),
              now = DateTime.now().toUtc();
          clock.receiptObserved(
            DateTime.parse(receiptAdmission!['startedAt']),
            now,
          );
          await _write(stateKey, clock.toJson());
        }
      }
      debugLog('$operation · ${result.outcome.name} · ${result.message}');
      return {
        'outcome': result.outcome.name,
        'reference': result.reference,
        ...result.fiscalIdentity,
        'message': result.message,
        ...(recordedPaymentRejection == null
            ? <String, Object?>{}
            : {'paymentRejection': recordedPaymentRejection}),
        if (operation == 'payment' &&
            result.outcome == CommandOutcome.succeeded &&
            result.reference?.isNotEmpty == true)
          ...await _security!.paymentEvidence(id, payload, result.reference!),
      };
    } finally {
      _executing = false;
      activeCommand = null;
      history = await _journal?.recent() ?? [];
      _changed();
      unawaited(refresh());
    }
  }

  Future<FiscalReceipt> _receipt(
    String id,
    Map<String, dynamic> payload,
    Map<String, dynamic> settings,
    CommandJournal journal,
  ) async {
    if (payload['lines'] is! List ||
        payload['totalMinor'] is! int ||
        payload['currency'] != 'RON' ||
        !['cash', 'card', 'loyalty'].contains(payload['paymentMethod'])) {
      throw ArgumentError('Invalid receipt');
    }
    String? reference;
    if (payload['paymentMethod'] == 'card') {
      reference = externalPaymentReference(id, payload);
      if (reference != null) {
        // Explicit manual mode: no Viva call and no simulated bank evidence.
      } else if (payload['paymentEvidence'] is String &&
          payload['paymentSignature'] is String &&
          _security != null) {
        reference = _security!.verifyPayment(
          payload['paymentEvidence'],
          payload['paymentSignature'],
          id,
          payload,
        );
      } else {
        if (payload['paymentCommandId'] is! String) {
          throw ArgumentError('Confirmed local payment required');
        }
        final endpoint = vivaEndpoint(
          settings['vivaHost'] as String? ?? '',
          settings['vivaPort'] as String? ?? '',
        );
        final result = await journal.lookup(
          id: payload['paymentCommandId'] as String,
          deviceId: '${endpoint.host}:${endpoint.port}',
          operation: 'payment',
          payload: {
            'vendor': 'viva',
            'amountMinor': receiptCardAmount(payload),
            'currency': 'RON',
          },
        );
        if (result?.outcome != CommandOutcome.succeeded ||
            (result?.reference?.isEmpty ?? true)) {
          throw ArgumentError('Card payment unconfirmed');
        }
        reference = result!.reference;
      }
    }
    final sourceLines = payload['lines'] as List;
    Map<String, double>? vatRates;
    if (payload['documentMode'] != 'nonfiscal' &&
        sourceLines.any((line) => line is Map && line['vatRate'] is num)) {
      vatRates = await _configuredDevice(settings).readVatRates();
    }
    final lines = sourceLines.map((line) {
      if (line is! Map ||
          line['name'] is! String ||
          line['quantity'] is! String ||
          line['unitPriceMinor'] is! int ||
          line['grossTotalMinor'] is! int ||
          (line['vatGroup'] is! String && line['vatRate'] is! num)) {
        throw ArgumentError('Invalid fiscal line');
      }
      return FiscalLine(
        name: line['name'] as String,
        quantityDecimal: line['quantity'] as String,
        unitPriceMinor: line['unitPriceMinor'] as int,
        grossTotalMinor: line['grossTotalMinor'] as int,
        vatGroup: payload['documentMode'] == 'nonfiscal'
            ? 'nonfiscal'
            : line['vatRate'] is num
            ? (vatRates!.entries
                      .where(
                        (entry) =>
                            (entry.value - (line['vatRate'] as num)).abs() <
                            0.001,
                      )
                      .firstOrNull
                      ?.key ??
                  (throw ArgumentError('VAT rate absent from ECR')))
            : line['vatGroup'] as String,
      );
    }).toList();
    return FiscalReceipt(
      commandId: id,
      currency: 'RON',
      lines: lines,
      totalMinor: payload['totalMinor'] as int,
      paymentMethod: FiscalPaymentMethod.values.byName(
        payload['paymentMethod'] as String,
      ),
      confirmedPaymentReference: reference,
      cui: payload['cui'] as String?,
      claimToken: payload['claimToken'] as String?,
      documentMode: payload['documentMode'] as String? ?? 'fiscal',
      payments: payload['settlementVersion'] == 2
          ? (payload['payments'] as List)
                .map(
                  (p) => ReceiptPayment(
                    method: FiscalPaymentMethod.values.byName(p['method']),
                    amountMinor: p['amountMinor'],
                  ),
                )
                .toList()
          : null,
    );
  }

  Future<void> close() async {
    _closed = true;
    await _scales?.close();
    await _console?.close();
    if (reportCompanionError == _errorReporter) reportCompanionError = null;
    _timer?.cancel();
    _connectivityTimer?.cancel();
    _erpCommandsTimer?.cancel();
    await _maintaining;
    await _server?.close();
    _server = null;
  }

  Future<void> _write(String key, Map<String, dynamic> value) =>
      _storage.write(key: key, value: jsonEncode(value));
}
