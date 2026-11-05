import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'device_credentials.dart';
import 'enrollment.dart';

/// Credentials and idempotent attempt identities stay outside the UI.
abstract interface class EnrollmentService {
  Future<Map<String, dynamic>?> restore();
  Future<Map<String, dynamic>> enroll(Uri origin, String pin);
}

class SecureEnrollmentService implements EnrollmentService {
  const SecureEnrollmentService();
  static const _storage = FlutterSecureStorage();

  @override
  Future<Map<String, dynamic>?> restore() async {
    final saved = await _storage.read(key: 'erp_pairing_v1');
    if (saved == null) return null;
    if (!hasSavedEnrollment(saved)) {
      throw const FormatException('Asocierea salvată nu poate fi citită.');
    }
    return jsonDecode(saved) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> enroll(Uri origin, String pin) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(enrollmentEndpoint(origin));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(await enrollmentProof(origin, pin)));
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 15));
      final data = parseEnrollmentResponse(response.statusCode, body);
      final saved = {
        ...data,
        'erp_url': enrolledErpAddress(data, origin).origin,
        'auth_url': enrolledAuthAddress(data, origin).origin,
      };
      await _storage.write(key: 'erp_pairing_v1', value: jsonEncode(saved));
      await _storage.delete(key: 'enrollment_attempt_v1');
      return saved;
    } finally {
      client.close(force: true);
    }
  }
}
