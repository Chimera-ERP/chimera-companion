import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'ble_permissions.dart';
import 'hardware/acaia_protocol.dart';
import 'hardware/acaia_scale.dart';
import 'hardware/scale.dart';

/// One service per persistent Flutter engine; scans stop when the page closes,
/// but the selected scale remains connected for the authenticated POS client.
class ScaleService extends ChangeNotifier {
  late final _ble = FlutterReactiveBle();
  static const _storage = FlutterSecureStorage();
  final devices = <String, DiscoveredDevice>{};
  ScaleAdapter? _adapter;
  StreamSubscription<DiscoveredDevice>? _scan;
  StreamSubscription<ScaleState>? _stateSubscription;
  StreamSubscription<ScaleReading>? _readingSubscription;
  Timer? _scanTimeout;
  int _scanGeneration = 0;
  bool _closed = false;
  bool scanning = false, connecting = false;
  ScaleState state = ScaleState.disconnected;
  String? selectedId, selectedName, error;
  ScaleReading? reading;
  Future<void> close() async {
    _closed = true;
    await stopScan();
    await _stateSubscription?.cancel();
    await _readingSubscription?.cancel();
    await _adapter?.disconnect();
  }

  Future<void> restore() async {
    if (_closed || selectedId != null || connecting) return;
    try {
      final saved = await _storage.read(key: 'ble_scale_v1');
      if (_closed || saved == null || selectedId != null || connecting) return;
      final value = jsonDecode(saved) as Map<String, dynamic>;
      selectedId = value['id'] as String;
      selectedName = value['name'] as String;
      // No permission prompt during background startup.
      await connect(selectedId!, selectedName!);
    } catch (_) {
      error = 'Reconectează cântarul din configurare.';
      notifyListeners();
    }
  }

  Future<void> scan() async {
    if (_closed || scanning || connecting) return;
    await stopScan();
    final generation = ++_scanGeneration;
    scanning = true;
    devices.clear();
    error = null;
    notifyListeners();
    try {
      await requireBluetooth(_ble);
      if (generation != _scanGeneration) return;
      _scan = _ble
          .scanForDevices(withServices: [], scanMode: ScanMode.lowLatency)
          .listen(
            (device) {
              if (generation != _scanGeneration) return;
              if (AcaiaProfile.matches(
                device.name,
                device.serviceUuids.map((id) => id.toString()),
              )) {
                if (devices.length < 100 || devices.containsKey(device.id)) {
                  devices[device.id] = device;
                }
                notifyListeners();
              }
            },
            onError: (Object _) {
              error = 'Scanarea Bluetooth a eșuat. Verifică permisiunile.';
              unawaited(stopScan());
            },
          );
      _scanTimeout = Timer(
        const Duration(seconds: 12),
        () => unawaited(stopScan()),
      );
    } catch (e) {
      error = e.toString().replaceFirst('Bad state: ', '');
      scanning = false;
    }
    notifyListeners();
  }

  Future<void> stopScan() async {
    ++_scanGeneration;
    _scanTimeout?.cancel();
    await _scan?.cancel();
    _scan = null;
    scanning = false;
    notifyListeners();
  }

  Future<void> connect(String id, String name) async {
    if (_closed || connecting) return;
    connecting = true;
    error = null;
    reading = null;
    notifyListeners();
    try {
      await stopScan();
      await _stateSubscription?.cancel();
      await _readingSubscription?.cancel();
      await _adapter?.disconnect();
      final adapter = AcaiaScale(_ble, id);
      _adapter = adapter;
      selectedId = id;
      selectedName = name.isEmpty ? 'Acaia' : name;
      _stateSubscription = adapter.states.listen((value) {
        state = value;
        error = adapter.configurationError;
        if (value != ScaleState.ready) reading = null;
        notifyListeners();
      });
      _readingSubscription = adapter.readings.listen((value) {
        reading = value;
        notifyListeners();
      });
      await adapter.connect();
      await _storage.write(
        key: 'ble_scale_v1',
        value: jsonEncode({'id': id, 'name': selectedName}),
      );
    } catch (_) {
      error =
          'Conexiunea a eșuat. Închide alte aplicații conectate la cântar și reîncearcă.';
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> forget() async {
    if (connecting) return;
    await _adapter?.disconnect();
    await _storage.delete(key: 'ble_scale_v1');
    selectedId = null;
    selectedName = null;
    reading = null;
    notifyListeners();
  }

  Future<Map<String, Object?>> snapshot() async {
    ScaleReading? current;
    if (state == ScaleState.ready) {
      try {
        current = await _adapter?.read();
      } catch (_) {}
    }
    return {
      'version': 1,
      'state': state.name,
      'name': selectedName,
      'stabilitySource': 'unavailable',
      'reading': current?.toJson(),
      'message':
          error ??
          (current == null
              ? 'Aștept configurarea automată și greutatea cântarului.'
              : 'Confirmă greutatea după stabilizarea cântarului.'),
    };
  }
}
