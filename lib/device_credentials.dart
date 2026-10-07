import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'security/device_identity.dart';

Map<String, dynamic> freshDeviceMessage(
  String purpose,
  Map<String, dynamic> fields,
) {
  final random = Random.secure();
  return {
    'purpose': purpose,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
    'nonce': base64UrlEncode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    ).replaceAll('=', ''),
    ...fields,
  };
}

String enrollmentAttemptId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Future<Map<String, dynamic>> enrollmentProof(
  Uri erp,
  String pin, {
  DeviceIdentity? identity,
}) async {
  const storage = FlutterSecureStorage();
  final saved = await storage.read(key: 'enrollment_attempt_v1');
  final prior = saved == null
      ? null
      : jsonDecode(saved) as Map<String, dynamic>;
  final attempt = prior?['erp'] == erp.origin && prior?['pin'] == pin
      ? prior!
      : {'erp': erp.origin, 'pin': pin, 'id': enrollmentAttemptId()};
  await storage.write(key: 'enrollment_attempt_v1', value: jsonEncode(attempt));
  final signer = identity ?? DeviceIdentity();
  final message = jsonEncode(
    freshDeviceMessage('enroll', {
      'enrollment_id': attempt['id'],
      'pin': pin,
      'device_type': 'COMPANION',
      'device_name': 'Chimera Companion',
      'public_jwk': await signer.publicKey(),
    }),
  );
  return {'message': message, 'signature': await signer.sign(message)};
}

final _renewals = <String, Future<Map<String, dynamic>>>{};
Map<String, dynamic> deviceTokenClaims(String token) =>
    jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(token.split('.')[1])),
          ),
        )
        as Map<String, dynamic>;

void validateRenewedDeviceToken(
  String previous,
  String next,
  String device, {
  DateTime? now,
}) {
  final before = deviceTokenClaims(previous), after = deviceTokenClaims(next);
  final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  if (after['device_id'] != device ||
      after['sub'] != device ||
      after['org'] != before['org'] ||
      after['aud'] != before['aud'] ||
      after['iss'] != before['iss'] ||
      after['role'] != 'companion' ||
      jsonEncode(after['locations']) != jsonEncode(before['locations']) ||
      after['exp'] is! int ||
      after['exp'] <= seconds ||
      after['exp'] > seconds + 86400 + 120) {
    throw const FormatException('Device renewal scope or lifetime mismatch');
  }
}

Future<Map<String, dynamic>> currentDevicePairing() async {
  const storage = FlutterSecureStorage();
  final raw = await storage.read(key: 'erp_pairing_v1');
  if (raw == null) throw StateError('ERP pairing required');
  final pairing = jsonDecode(raw) as Map<String, dynamic>;
  final claims =
      jsonDecode(
            utf8.decode(
              base64Url.decode(
                base64Url.normalize((pairing['token'] as String).split('.')[1]),
              ),
            ),
          )
          as Map<String, dynamic>;
  if (claims['device_key'] is String &&
      claims['exp'] is int &&
      claims['exp'] > DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600) {
    return pairing;
  }
  final device = pairing['device_id'] as String;
  return _renewals.putIfAbsent(
    device,
    () => _renewPairing(pairing).whenComplete(() => _renewals.remove(device)),
  );
}

Future<Map<String, dynamic>> _renewPairing(Map<String, dynamic> pairing) async {
  final signer = DeviceIdentity();
  final message = jsonEncode(
    freshDeviceMessage('renew', {'device_id': pairing['device_id']}),
  );
  final erp = Uri.parse(pairing['erp_url'] as String);
  if (erp.scheme != 'https') throw const FormatException('HTTPS required');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.postUrl(erp.resolve('/auth/device-token'));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({'message': message, 'signature': await signer.sign(message)}),
    );
    final response = await request.close().timeout(const Duration(seconds: 10));
    if ([502, 503, 504].contains(response.statusCode)) {
      throw const SocketException('ERP temporar indisponibil');
    }
    if (response.statusCode != 200) {
      throw HttpException('Device renewal rejected (${response.statusCode})');
    }
    final result =
        jsonDecode(
              await utf8.decoder
                  .bind(response)
                  .join()
                  .timeout(const Duration(seconds: 5)),
            )
            as Map<String, dynamic>;
    if (result['device_id'] != pairing['device_id'] ||
        result['token'] is! String) {
      throw const FormatException('Invalid device renewal');
    }
    validateRenewedDeviceToken(
      pairing['token'] as String,
      result['token'] as String,
      pairing['device_id'] as String,
    );
    final updated = {...pairing, 'token': result['token']};
    await const FlutterSecureStorage().write(
      key: 'erp_pairing_v1',
      value: jsonEncode(updated),
    );
    return updated;
  } finally {
    client.close(force: true);
  }
}
