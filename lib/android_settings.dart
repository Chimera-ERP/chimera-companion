import 'package:flutter/services.dart';

/// Opens settings only: never grants permissions or changes Android configuration.
class AndroidSettings {
  static const channel = MethodChannel('chimera/settings');
  static Future<void> open(String page) =>
      channel.invokeMethod<void>('open', {'page': page});
}
