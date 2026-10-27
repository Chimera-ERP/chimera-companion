import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import '../ble_permissions.dart';
import 'niimbot_protocol.dart';

const niimbotService = 'e7810a71-73ae-499d-8c15-faa9aef0c3f2';

abstract interface class NiimbotLink {
  Stream<List<int>> get notifications;
  Future<void> write(List<int> bytes);
  Future<void> close();
}

class NiimbotGatt implements NiimbotLink {
  NiimbotGatt(this.ble);
  final FlutterReactiveBle ble;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  StreamSubscription<List<int>>? _notification;
  final _data = StreamController<List<int>>.broadcast();
  late QualifiedCharacteristic _write;
  @override
  Stream<List<int>> get notifications => _data.stream;

  Future<void> open(String id) async {
    final connected = Completer<void>();
    void fail(Object e) {
      if (!connected.isCompleted) connected.completeError(e);
      if (!_data.isClosed) _data.addError(e);
    }

    _connection = ble
        .connectToDevice(id: id, connectionTimeout: const Duration(seconds: 10))
        .listen((event) {
          if (event.connectionState == DeviceConnectionState.connected &&
              !connected.isCompleted) {
            connected.complete();
          } else if (event.connectionState ==
              DeviceConnectionState.disconnected) {
            fail(
              StateError(
                'Imprimanta s-a deconectat. Rezultatul poate fi necunoscut; nu retrimite automat.',
              ),
            );
          }
        }, onError: fail);
    await connected.future.timeout(const Duration(seconds: 12));
    await ble.discoverAllServices(id).timeout(const Duration(seconds: 8));
    final services = await ble
        .getDiscoveredServices(id)
        .timeout(const Duration(seconds: 8));
    final service = services.firstWhere(
      (s) => s.id == Uuid.parse(niimbotService),
      orElse: () =>
          throw UnsupportedError('Serviciul NIIMBOT BLE nu este disponibil.'),
    );
    final tx = service.characteristics.firstWhere(
      (c) => c.isWritableWithoutResponse,
      orElse: () => throw UnsupportedError('Canal NIIMBOT write indisponibil.'),
    );
    final rx = service.characteristics.firstWhere(
      (c) => c.isNotifiable,
      orElse: () =>
          throw UnsupportedError('Canal NIIMBOT notify indisponibil.'),
    );
    QualifiedCharacteristic qualified(Uuid uuid) => QualifiedCharacteristic(
      characteristicId: uuid,
      serviceId: service.id,
      deviceId: id,
    );
    _write = qualified(tx.id);
    _notification = ble
        .subscribeToCharacteristic(qualified(rx.id))
        .listen(_data.add, onError: fail);
    // Let Android complete CCCD subscription before the initial negotiation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<void> write(List<int> bytes) async {
    // ATT minimum MTU23: payload20 works even when MTU negotiation is unavailable.
    for (var i = 0; i < bytes.length; i += 20) {
      await ble
          .writeCharacteristicWithoutResponse(
            _write,
            value: bytes.sublist(i, (i + 20).clamp(0, bytes.length)),
          )
          .timeout(const Duration(seconds: 4));
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
  }

  @override
  Future<void> close() async {
    await _notification?.cancel();
    await _connection?.cancel();
    await _data.close();
  }
}

class NiimbotSession {
  NiimbotSession(this.link) {
    _subscription = link.notifications.listen(
      (bytes) {
        for (final packet in _decoder.add(bytes)) {
          if (packet.command == 0xdb || packet.command == 0) {
            _failure = StateError(
              'NIIMBOT a refuzat comanda (${packet.data.join(',')}).',
            );
            _pending?.completeError(_failure!);
            _pending = null;
          } else if (packet.command == _expected && _pending != null) {
            _pending!.complete(packet.data);
            _pending = null;
          }
        }
      },
      onError: (Object e) {
        _failure = e;
        _pending?.completeError(e);
        _pending = null;
      },
    );
  }
  final NiimbotLink link;
  final _decoder = NiimbotDecoder();
  late final StreamSubscription<List<int>> _subscription;
  Completer<List<int>>? _pending;
  int? _expected;
  Object? _failure;
  Future<List<int>> request(
    int command,
    int response, [
    List<int> data = const [1],
  ]) async {
    if (_failure != null) throw _failure!;
    if (_pending != null) throw StateError('Concurrent NIIMBOT request');
    final pending = _pending = Completer<List<int>>();
    _expected = response;
    // Attach the timeout/error handler before I/O can deliver a response.
    final reply = pending.future.timeout(const Duration(seconds: 5));
    // Observe write failure and asynchronous disconnect without orphaning a future.
    unawaited(reply.catchError((Object _) => <int>[]));
    try {
      await link.write(NiimbotPacket(command, data).encode());
      return await reply;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  Future<NiimbotModel> identify() async {
    final hello = await request(0xc1, 0xc2);
    if (hello.isEmpty || ![1, 2, 3].contains(hello.first)) {
      throw StateError('NIIMBOT nu a acceptat conexiunea.');
    }
    if (hello.first == 3) {
      final status = await request(0xa5, 0xb5);
      if (status.length < 13 || status[11] * 100 + status[12] >= 300) {
        throw UnsupportedError('NIIMBOT protocol V4/V5: încă neimplementat.');
      }
    }
    final code = await request(0x40, 0x48, [8]);
    if (code.isEmpty || code.length > 2) {
      throw const FormatException('Invalid model reply');
    }
    return NiimbotModel.fromId(
      (code.first << 8) | (code.length == 2 ? code[1] : 0),
    );
  }

  Future<void> accepted(
    int command,
    int response, [
    List<int> data = const [1],
  ]) async {
    final result = await request(command, response, data);
    if (result.isEmpty || result.first != 1) {
      throw StateError('NIIMBOT comanda $command refuzată.');
    }
  }

  Future<void> printBitmap(
    NiimbotModel expected,
    int width,
    int height,
    List<int> bitmap,
  ) async {
    if (width < 8 ||
        width > expected.width ||
        width % 8 != 0 ||
        height < 1 ||
        height > 2400 ||
        bitmap.length != width ~/ 8 * height) {
      throw const FormatException('Invalid NIIMBOT raster');
    }
    final actual = await identify();
    if (actual.id != expected.id) {
      throw StateError('Modelul imprimantei s-a schimbat. Reconfigurează.');
    }
    await accepted(0x21, 0x31, [actual.density]);
    await accepted(0x23, 0x33, [
      1,
    ]); // Gap labels only, explicitly shown in setup.
    await accepted(1, 2, actual.b1 ? [0, 1, 0, 0, 0, 0, 0] : [1]);
    if (!actual.b1) await accepted(0x20, 0x30);
    await accepted(3, 4);
    await accepted(0x13, 0x14, [
      ...niimbotU16(height),
      ...niimbotU16(width),
      if (actual.b1) ...[0, 1],
    ]);
    if (!actual.b1) await accepted(0x15, 0x16, [0, 1]);
    for (var row = 0; row < height; row++) {
      if (_failure != null) throw _failure!;
      await link.write(
        niimbotRow(
          row,
          bitmap.sublist(row * (width ~/ 8), (row + 1) * (width ~/ 8)),
          actual.width,
        ).encode(),
      );
    }
    await accepted(0xe3, 0xe4);
    var complete = false;
    for (var poll = 0; poll < 60; poll++) {
      final status = await request(0xa3, 0xb3);
      if (status.length < 4 || (status.length == 10 && status[6] != 0)) {
        throw StateError('NIIMBOT a raportat o eroare de imprimare.');
      }
      if (((status[0] << 8) | status[1]) >= 1 &&
          status[2] == 100 &&
          status[3] == 100) {
        complete = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!complete) {
      throw TimeoutException('Imprimare neconfirmată; nu retrimite automat.');
    }
    await accepted(0xf3, 0xf4);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await link.close();
  }
}

class NiimbotDiscovery extends ChangeNotifier {
  late final _ble = FlutterReactiveBle();
  final devices = <String, DiscoveredDevice>{};
  bool scanning = false, connecting = false, _closed = false;
  String? error, selectedId;
  NiimbotModel? model;
  StreamSubscription<DiscoveredDevice>? _scan;
  Timer? _timer;
  int _generation = 0;
  Future<void> stop() async {
    _timer?.cancel();
    await _scan?.cancel();
    _scan = null;
    scanning = false;
    if (!_closed) notifyListeners();
  }

  Future<void> scan() async {
    if (_closed || scanning || connecting) return;
    final generation = ++_generation;
    scanning = true;
    error = null;
    devices.clear();
    notifyListeners();
    try {
      await requireBluetooth(_ble);
      if (_closed || generation != _generation) return;
      _scan = _ble
          .scanForDevices(withServices: [], scanMode: ScanMode.lowLatency)
          .listen(
            (d) {
              if (_closed || generation != _generation) return;
              if (d.serviceUuids.contains(Uuid.parse(niimbotService)) ||
                  RegExp(
                    r'^(NIIMBOT|B\d|D\d|N\d|M\d)',
                    caseSensitive: false,
                  ).hasMatch(d.name)) {
                if (devices.length < 100 || devices.containsKey(d.id)) {
                  devices[d.id] = d;
                }
                notifyListeners();
              }
            },
            onError: (Object _) {
              if (!_closed) {
                error = 'Scanarea a eșuat. Verifică Bluetooth și permisiunile.';
              }
              unawaited(stop());
            },
          );
      _timer = Timer(const Duration(seconds: 12), () => unawaited(stop()));
    } catch (e) {
      if (!_closed) error = '$e';
      await stop();
    }
  }

  Future<void> select(String id) async {
    if (_closed || connecting) return;
    await stop();
    connecting = true;
    model = null;
    selectedId = null;
    error = null;
    notifyListeners();
    final gatt = NiimbotGatt(_ble);
    final session = NiimbotSession(gatt);
    try {
      await gatt.open(id);
      final found = await session.identify();
      if (!_closed) {
        model = found;
        selectedId = id;
      }
    } catch (e) {
      if (!_closed) error = '$e';
    } finally {
      await session.close();
      connecting = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    unawaited(stop());
    // In-flight identification is bounded and closes its connection in finally.
    super.dispose();
  }
}

Future<void> sendNiimbot(
  String id,
  int modelId,
  int width,
  int height,
  List<int> raster,
) async {
  final gatt = NiimbotGatt(FlutterReactiveBle());
  final session = NiimbotSession(gatt);
  try {
    await gatt.open(id);
    await session.printBitmap(
      NiimbotModel.fromId(modelId),
      width,
      height,
      raster,
    );
  } finally {
    await session.close();
  }
}
