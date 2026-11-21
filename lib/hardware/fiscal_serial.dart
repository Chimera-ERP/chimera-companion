import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../android_settings.dart';
import 'connection.dart';
import 'fiscal_byte_session.dart';

typedef FiscalSerialDevice = ({String id, String label});

/// Selection is a foreground setup action. Reconnecting a saved register must
/// never open a permission dialog or select another attachment.
abstract final class FiscalSerial {
  static const channel = MethodChannel('chimera/fiscal-serial');

  static Future<List<FiscalSerialDevice>> devices(String transport) async {
    if (transport == 'bluetooth') {
      final sdk =
          await AndroidSettings.channel.invokeMethod<int>('sdkInt') ?? 31;
      if (sdk >= 31 &&
          !(await Permission.bluetoothConnect.request()).isGranted) {
        throw PlatformException(
          code: 'nearby_permission',
          message:
              'Permite accesul la dispozitivele din apropiere, apoi actualizează lista.',
        );
      }
    }
    final rows = await channel.invokeListMethod<Object?>('devices', {
      'transport': transport,
    });
    return [
      for (final row in rows ?? const [])
        if (row case {'id': final String id, 'label': final String label})
          (id: id, label: label),
    ];
  }

  static Future<String> select(
    String transport,
    String id, {
    required FiscalModel model,
    required int baudRate,
    required bool legacyDatecs,
  }) async {
    final deviceId = await channel.invokeMethod<String>('select', {
      'transport': transport,
      'id': id,
      'model': model.name,
      'baudRate': baudRate,
    });
    if (transport == 'usb') {
      return FiscalByteSession.bindUsb(
        id,
        model: model,
        baudRate: baudRate,
        legacyDatecs: legacyDatecs,
      );
    }
    if (deviceId == null || deviceId.isEmpty) {
      throw const FormatException(
        'Casa nu a furnizat un identificator stabil.',
      );
    }
    return deviceId;
  }
}
