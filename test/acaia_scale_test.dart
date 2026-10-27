import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:chimera_companion/hardware/acaia_protocol.dart';
import 'package:chimera_companion/hardware/acaia_scale.dart';
import 'package:chimera_companion/hardware/scale.dart';

class TestCharacteristic implements Characteristic {
  TestCharacteristic(this.id);
  @override
  final Uuid id;
  @override
  bool get isWritableWithoutResponse => true;
  @override
  bool get isWritableWithResponse => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestService implements Service {
  TestService(this.profile);
  final AcaiaProfile profile;
  @override
  Uuid get id => Uuid.parse(profile.service);
  @override
  List<Characteristic> get characteristics => [
    TestCharacteristic(Uuid.parse(profile.command)),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestBle implements FlutterReactiveBle {
  TestBle(this.profile);
  final AcaiaProfile profile;
  final connection = StreamController<ConnectionStateUpdate>();
  final notifications = StreamController<List<int>>();
  final writes = <List<int>>[];
  bool subscribed = false;
  bool rejectSettings = false;
  @override
  Stream<ConnectionStateUpdate> connectToDevice({
    required String id,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connection.add(
      ConnectionStateUpdate(
        deviceId: id,
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
    return connection.stream;
  }

  @override
  Future<void> discoverAllServices(String deviceId) async {}
  @override
  Future<List<Service>> getDiscoveredServices(String deviceId) async => [
    TestService(profile),
  ];
  @override
  Stream<List<int>> subscribeToCharacteristic(
    QualifiedCharacteristic characteristic,
  ) {
    subscribed = true;
    return notifications.stream;
  }

  @override
  Future<void> writeCharacteristicWithoutResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) async {
    expect(subscribed, true);
    writes.add(value);
    if (rejectSettings && value[2] == 10) throw StateError('BLE rejected');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final profile in AcaiaProfile.profiles) {
    test('handshake and safe readings for ${profile.service}', () async {
      final ble = TestBle(profile);
      final scale = AcaiaScale(ble, 'synthetic');
      await scale.connect();
      expect(
        ble.writes.first,
        AcaiaProtocol.frame(0x0b, List.filled(15, 0x2d)),
      );
      final weight = AcaiaProtocol.frame(12, [
        8,
        5,
        ...profile.umbra ? [0, 0, 0x0d, 0xac, 1, 0] : [0xac, 0x0d, 0, 0, 1, 0],
      ]);
      ble.notifications.add(weight);
      await Future<void>.delayed(Duration.zero);
      await expectLater(scale.read(), throwsStateError); // No confirmed units.
      ble.notifications.add(
        AcaiaProtocol.frame(8, profile.umbra ? [5, 80, 2, 1, 0] : [3, 80, 2]),
      );
      ble.notifications.add(weight);
      await Future<void>.delayed(Duration.zero);
      expect((await scale.read()).net, '350.0');
      expect((await scale.read()).stable, false); // Never invent stability.
      ble.notifications.add(
        AcaiaProtocol.frame(8, profile.umbra ? [5, 80, 2, 1, 1] : [3, 80, 5]),
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        scale.read(),
        throwsStateError,
      ); // Ounces are not grams.
      await scale.disconnect();
      await expectLater(scale.read(), throwsStateError);
      await ble.notifications.close();
      await ble.connection.close();
    });
  }
  for (final profile in AcaiaProfile.profiles) {
    test(
      'unit write is bounded and requires readback ${profile.service}',
      () async {
        final ble = TestBle(profile);
        final scale = AcaiaScale(ble, 'synthetic');
        await scale.connect();
        final ounces = AcaiaProtocol.frame(
          8,
          profile.umbra ? [5, 80, 2, 1, 1] : [3, 80, 5],
        );
        for (var i = 0; i < 4; i++) {
          ble.notifications.add(ounces);
        }
        await Future<void>.delayed(Duration.zero);
        final writes = ble.writes.where((v) => v[2] == 10).toList();
        if (profile.supportsUnitWrite) {
          // Literal wire fixtures: not generated from the production encoder.
          expect(writes, [
            profile.umbra
                ? [239, 221, 10, 0, 8, 0, 0, 8]
                : [239, 221, 10, 0, 0, 2, 2, 0],
          ]);
          expect(ble.writes.last, [239, 221, 6, 0, 0, 0]);
        } else {
          expect(writes, isEmpty);
          expect(scale.configurationError, contains('vechi'));
        }
        final weight = AcaiaProtocol.frame(12, [
          8,
          5,
          ...profile.umbra
              ? [0, 0, 0x0d, 0xac, 1, 0]
              : [0xac, 0x0d, 0, 0, 1, 0],
        ]);
        ble.notifications.add(weight);
        await Future<void>.delayed(Duration.zero);
        await expectLater(scale.read(), throwsStateError);
        ble.notifications.add(
          AcaiaProtocol.frame(
            8,
            profile.umbra ? [5, 80, 2, 1, 0] : [3, 80, 0x82],
          ),
        );
        ble.notifications.add(weight);
        await Future<void>.delayed(Duration.zero);
        expect((await scale.read()).net, '350.0');
        expect(scale.configurationError, isNull);
        await scale.disconnect();
        await ble.notifications.close();
        await ble.connection.close();
      },
    );
  }
  test('missing readback times out without repeated writes', () async {
    final ble = TestBle(AcaiaProfile.profiles[1]);
    final scale = AcaiaScale(
      ble,
      'synthetic',
      unitConfirmationTimeout: const Duration(milliseconds: 30),
    );
    final states = <ScaleState>[];
    scale.states.listen(states.add);
    await scale.connect();
    ble.notifications.add(AcaiaProtocol.frame(8, [3, 80, 5]));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(scale.configurationError, contains('nu a confirmat'));
    expect(states.last, ScaleState.error);
    expect(ble.writes.where((v) => v[2] == 10), hasLength(1));
    await scale.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(states.last, ScaleState.disconnected);
    await ble.notifications.close();
    await ble.connection.close();
  });
  test('disconnect during configuration cancels pending deadline', () async {
    final ble = TestBle(AcaiaProfile.profiles[1]);
    final scale = AcaiaScale(
      ble,
      'synthetic',
      unitConfirmationTimeout: const Duration(milliseconds: 30),
    );
    final states = <ScaleState>[];
    scale.states.listen(states.add);
    await scale.connect();
    ble.notifications.add(AcaiaProtocol.frame(8, [3, 80, 5]));
    await Future<void>.delayed(Duration.zero);
    await scale.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(states.last, ScaleState.disconnected);
    expect(scale.configurationError, isNull);
    expect(ble.writes.where((v) => v[2] == 10), hasLength(1));
    await ble.notifications.close();
    await ble.connection.close();
  });
  test('failed setting write blocks measurements', () async {
    final ble = TestBle(AcaiaProfile.profiles[1])..rejectSettings = true;
    final scale = AcaiaScale(ble, 'synthetic');
    await scale.connect();
    ble.notifications.add(AcaiaProtocol.frame(8, [3, 80, 5]));
    await Future<void>.delayed(Duration.zero);
    expect(scale.configurationError, contains('eșuat'));
    await expectLater(scale.read(), throwsStateError);
    await scale.disconnect();
    await ble.notifications.close();
    await ble.connection.close();
  });
  test('grams and unknown units never trigger speculative writes', () async {
    final ble = TestBle(AcaiaProfile.profiles[1]);
    final scale = AcaiaScale(ble, 'synthetic');
    await scale.connect();
    for (final unit in [99, 2, 2]) {
      ble.notifications.add(AcaiaProtocol.frame(8, [3, 80, unit]));
    }
    await Future<void>.delayed(Duration.zero);
    expect(ble.writes.where((v) => v[2] == 10), isEmpty);
    await scale.disconnect();
    await ble.notifications.close();
    await ble.connection.close();
  });
}
