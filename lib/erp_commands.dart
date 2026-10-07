import 'dart:convert';
import 'package:crypto/crypto.dart';

String canonicalJson(dynamic value) {
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${canonicalJson(value[key])}').join(',')}}';
  }
  return jsonEncode(value);
}

String hardwarePayloadHash(dynamic value) =>
    sha256.convert(utf8.encode(canonicalJson(value))).toString();

/// Polling never turns a lost response into permission to dispatch again.
class ErpCommands {
  ErpCommands({
    required this.post,
    required this.verify,
    required this.dispatch,
    required this.recover,
    required this.sign,
  });
  final Future<Map<String, dynamic>> Function(String, Map<String, Object?>)
  post;
  final Map<String, dynamic> Function(String, Map<String, dynamic>) verify;
  final Future<Map<String, Object?>> Function(
    Map<String, dynamic>,
    Map<String, dynamic>,
  ) dispatch,
      recover;
  final Future<String> Function(String) sign;
  Future<void>? _polling;
  Future<void> poll() =>
      _polling ??= _poll().whenComplete(() => _polling = null);
  Future<void> _poll() async {
    final response = await post('/api/devices/companion/management/pull', {});
    for (final item in response['commands'] as List? ?? []) {
      final payload = Map<String, dynamic>.from(item['payload']);
      final grant = verify(item['ticket'] as String, payload);
      if (grant['commandId'] != item['id'] ||
          !(grant['operations'] as List).contains(item['operation'])) {
        throw const FormatException('ERP command scope mismatch');
      }
      final result = grant['dispatch'] == true
          ? await dispatch(grant, payload)
          : await recover(grant, payload);
      final message = jsonEncode({...result, 'commandId': item['id']});
      await post('/api/devices/companion/management/result', {
        'message': message,
        'signature': await sign(message),
      });
    }
  }
}
