import 'dart:async';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'acaia_protocol.dart';
import 'scale.dart';

/// Acaia does not expose a verified stability flag in this protocol. Stability
/// is deliberately not fabricated: POS accepts the live value explicitly.
class AcaiaScale implements ScaleAdapter {
  AcaiaScale(
    this.ble,
    this.deviceId, {
    this.unitConfirmationTimeout = const Duration(seconds: 8),
  });
  final Duration unitConfirmationTimeout;
  final FlutterReactiveBle ble;
  @override
  final String deviceId;
  @override
  ScaleCapabilities get capabilities => const ScaleCapabilities(tare: true);
  final _states = StreamController<ScaleState>.broadcast();
  final _readings = StreamController<ScaleReading>.broadcast();
  @override
  Stream<ScaleState> get states => _states.stream;
  @override
  Stream<ScaleReading> get readings => _readings.stream;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  StreamSubscription<List<int>>? _notifications;
  Timer? _heartbeat;
  Timer? _unitDeadline;
  bool _unitWriteAttempted = false;
  String? configurationError;
  QualifiedCharacteristic? _command;
  bool _writeResponse = false, _grams = false, _writing = false;
  int _generation = 0;
  ScaleReading? _latest;
  Future<void> _send(int type, List<int> payload) async {
    final command = _command;
    if (command == null) throw StateError('Cântar deconectat');
    final value = AcaiaProtocol.frame(type, payload);
    if (_writeResponse) {
      await ble.writeCharacteristicWithResponse(command, value: value);
    } else {
      await ble.writeCharacteristicWithoutResponse(command, value: value);
    }
  }

  Future<void> _ping() async {
    if (_writing) return;
    _writing = true;
    try {
      await _send(0, [2, 0]);
      await _send(0x0c, [9, 0, 1, 1, 2, 2, 5, 3, 4]);
      await _send(6, [0]);
    } finally {
      _writing = false;
    }
  }

  @override
  Future<void> connect() async {
    await disconnect();
    final generation = ++_generation;
    _states.add(ScaleState.connecting);
    final connected = Completer<void>();
    _connection = ble
        .connectToDevice(
          id: deviceId,
          connectionTimeout: const Duration(seconds: 10),
        )
        .listen(
          (event) {
            if (generation != _generation) return;
            if (event.connectionState == DeviceConnectionState.connected &&
                !connected.isCompleted) {
              connected.complete();
            }
            if (event.connectionState == DeviceConnectionState.disconnected) {
              _latest = null;
              _heartbeat?.cancel();
              _unitDeadline?.cancel();
              _grams = false;
              _command = null;
              _states.add(ScaleState.disconnected);
              if (!connected.isCompleted) {
                connected.completeError(
                  StateError('Conexiune Bluetooth întreruptă'),
                );
              }
            }
          },
          onError: (Object error) {
            if (generation != _generation) return;
            _latest = null;
            _heartbeat?.cancel();
            _unitDeadline?.cancel();
            _grams = false;
            _states.add(ScaleState.error);
            if (!connected.isCompleted) connected.completeError(error);
          },
        );
    try {
      await connected.future.timeout(const Duration(seconds: 12));
      await ble
          .discoverAllServices(deviceId)
          .timeout(const Duration(seconds: 10));
      final services = await ble
          .getDiscoveredServices(deviceId)
          .timeout(const Duration(seconds: 5));
      final profile = AcaiaProfile.profiles.firstWhere(
        (p) => services.any((s) => s.id.toString().toLowerCase() == p.service),
      );
      final service = services.firstWhere(
        (s) => s.id.toString().toLowerCase() == profile.service,
      );
      final characteristic = service.characteristics.firstWhere(
        (c) => c.id.toString().toLowerCase() == profile.command,
      );
      _writeResponse = !characteristic.isWritableWithoutResponse;
      if (!characteristic.isWritableWithResponse &&
          !characteristic.isWritableWithoutResponse) {
        throw StateError('Cântar incompatibil');
      }
      _command = QualifiedCharacteristic(
        deviceId: deviceId,
        serviceId: Uuid.parse(profile.service),
        characteristicId: Uuid.parse(profile.command),
      );
      final parser = AcaiaProtocol();
      _notifications = ble
          .subscribeToCharacteristic(
            QualifiedCharacteristic(
              deviceId: deviceId,
              serviceId: Uuid.parse(profile.service),
              characteristicId: Uuid.parse(profile.notify),
            ),
          )
          .listen(
            (bytes) {
              if (generation != _generation) return;
              for (final packet in parser.accept(bytes)) {
                if (packet.type == 8) {
                  final grams = profile.statusIsGrams(packet.payload);
                  _grams = grams == true;
                  if (_grams) {
                    _unitDeadline?.cancel();
                    configurationError = null;
                    _states.add(ScaleState.ready);
                  } else {
                    _latest = null;
                    if (grams == false && !profile.supportsUnitWrite) {
                      _unitFailure(
                        'Acest protocol Acaia vechi nu permite configurarea unității prin BLE.',
                      );
                    } else if (grams == false && !_unitWriteAttempted) {
                      _unitWriteAttempted = true;
                      _states.add(ScaleState.connecting);
                      _startUnitDeadline(generation);
                      unawaited(_configureGrams(profile, generation));
                    } else if (configurationError == null) {
                      _states.add(ScaleState.connecting);
                      if (!(_unitDeadline?.isActive ?? false)) {
                        _startUnitDeadline(generation);
                      }
                    }
                  }
                }
                if (packet.type != 0x0c ||
                    packet.payload.length < 8 ||
                    packet.payload[1] != 5) {
                  continue;
                }
                final value = AcaiaProtocol.weight(
                  packet.payload.sublist(2),
                  umbra: profile.umbra,
                );
                if (value == null || !_grams) {
                  _latest = null;
                  continue;
                }
                final reading = ScaleReading(
                  deviceId: deviceId,
                  net: value,
                  unit: ScaleUnit.g,
                  stable: false,
                  observedAt: DateTime.now(),
                );
                _latest = reading;
                _readings.add(reading);
              }
            },
            onError: (Object _) {
              if (generation != _generation) return;
              _latest = null;
              _grams = false;
              _states.add(ScaleState.error);
            },
          );
      await _send(0x0b, List.filled(15, 0x2d));
      await _ping();
      if (generation != _generation) return;
      if (!_grams &&
          configurationError == null &&
          !(_unitDeadline?.isActive ?? false)) {
        _startUnitDeadline(generation);
      }
      _heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(
          _ping().catchError((Object _) {
            if (generation != _generation) return;
            _latest = null;
            _states.add(ScaleState.error);
          }),
        );
      });
    } catch (_) {
      await disconnect();
      _states.add(ScaleState.error);
      rethrow;
    }
  }

  void _unitFailure(String message) {
    _latest = null;
    _grams = false;
    configurationError = message;
    _unitDeadline?.cancel();
    _states.add(ScaleState.error);
  }

  void _startUnitDeadline(int generation) {
    _unitDeadline?.cancel();
    _unitDeadline = Timer(unitConfirmationTimeout, () {
      if (generation == _generation && !_grams) {
        _unitFailure(
          'Cântarul nu a confirmat unitatea în grame. Reconectează pentru a reîncerca.',
        );
      }
    });
  }

  Future<void> _configureGrams(AcaiaProfile profile, int generation) async {
    try {
      await _send(10, profile.gramsSetting).timeout(const Duration(seconds: 5));
      if (generation != _generation) return;
      // A successful BLE write is not confirmation: request device readback.
      await _send(6, [0]).timeout(const Duration(seconds: 5));
    } catch (_) {
      if (generation == _generation) {
        _unitFailure(
          'Configurarea automată a cântarului a eșuat. Reconectează pentru a reîncerca.',
        );
      }
    }
  }

  @override
  Future<ScaleReading> read() async {
    final value = _latest;
    if (value == null ||
        DateTime.now().difference(value.observedAt) >
            const Duration(seconds: 2)) {
      throw StateError(
        configurationError ??
            'Aștept configurarea automată și greutatea cântarului.',
      );
    }
    return value;
  }

  @override
  Future<void> tare() async {
    _latest = null;
    await _send(4, [0]);
  }

  @override
  Future<void> zero() => Future.error(UnsupportedError('Zero indisponibil'));
  @override
  Future<void> disconnect() async {
    ++_generation;
    _heartbeat?.cancel();
    _heartbeat = null;
    _unitDeadline?.cancel();
    _unitDeadline = null;
    _unitWriteAttempted = false;
    configurationError = null;
    _latest = null;
    _grams = false;
    _command = null;
    await _notifications?.cancel();
    _notifications = null;
    await _connection?.cancel();
    _connection = null;
    _states.add(ScaleState.disconnected);
  }
}
