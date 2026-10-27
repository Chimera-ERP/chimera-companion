import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'android_settings.dart';

/// Explicit setup actions only; never prompt during background reconnection.
Future<void> requireBluetooth(FlutterReactiveBle ble) async {
  final sdk = await AndroidSettings.channel.invokeMethod<int>('sdkInt') ?? 31;
  final permissions =
      await (sdk >= 31
              ? [Permission.bluetoothScan, Permission.bluetoothConnect]
              : [Permission.locationWhenInUse])
          .request();
  if (permissions.values.any((s) => !s.isGranted)) {
    throw StateError('Permite accesul Bluetooth din setările aplicației.');
  }
  final status = ble.status == BleStatus.ready
      ? BleStatus.ready
      : await ble.statusStream
            .firstWhere((s) => s != BleStatus.unknown)
            .timeout(const Duration(seconds: 5));
  if (status != BleStatus.ready) {
    throw StateError(
      'Activează Bluetooth și permisiunile pentru dispozitive din apropiere.',
    );
  }
}
