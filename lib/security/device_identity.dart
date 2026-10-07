import 'package:flutter/services.dart';

class DeviceIdentity {
  static const _channel = MethodChannel('chimera/identity');
  Future<Map<String, dynamic>> publicKey() async {
    final value = await _channel.invokeMapMethod<String, dynamic>('publicKey');
    if (value == null) throw StateError('Device identity unavailable');
    return value;
  }

  Future<String> sign(String message) async {
    final value = await _channel.invokeMethod<String>('sign', {
      'message': message,
    });
    if (value == null) throw StateError('Device identity unavailable');
    return value;
  }
}
