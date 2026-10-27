import 'package:flutter/services.dart';

abstract interface class ConsoleTransport {
  Stream<Uint8List> get reports;
  Future<List<Map<String, dynamic>>> devices();
  Future<void> open(String id);
  Future<void> write(List<Uint8List> packets);
  Future<void> close();
}

/// Native USB only. Browser APIs and keyboard emulation are not used.
class NativeConsoleTransport implements ConsoleTransport {
  bool _opened = false;
  static const _method = MethodChannel('chimera/console');
  static const _events = EventChannel('chimera/console/reports');
  @override
  Stream<Uint8List> get reports =>
      _events.receiveBroadcastStream().map((value) => value as Uint8List);
  @override
  Future<List<Map<String, dynamic>>> devices() async =>
      (await _method.invokeListMethod<Object?>('devices') ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  @override
  Future<void> open(String id) async {
    await _method.invokeMethod('open', {'id': id});
    _opened = true;
  }

  @override
  Future<void> write(List<Uint8List> packets) =>
      _method.invokeMethod('write', packets);
  @override
  Future<void> close() async {
    if (!_opened) return;
    _opened = false;
    await _method.invokeMethod('close');
  }
}
