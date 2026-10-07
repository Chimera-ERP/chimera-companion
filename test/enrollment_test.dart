import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/enrollment.dart';

void main() {
  test('ERP hostname defaults to HTTPS and accepts pasted HTTPS addresses', () {
    expect(
      erpAddress('chimera.example.com').origin,
      'https://chimera.example.com',
    );
    expect(
      erpAddress(' https://chimera.example.com/ ').origin,
      'https://chimera.example.com',
    );
    for (final address in [
      'http://chimera.example.com',
      'https://user:pass@chimera.example.com',
      '',
    ]) {
      expect(() => erpAddress(address), throwsFormatException);
    }
  });
  test('uses the public auth route instead of the UI-only Vite proxy', () {
    expect(
      enrollmentEndpoint(Uri.parse('https://devchimera.tabusociety.ro')),
      Uri.parse('https://devchimera.tabusociety.ro/auth/enroll-device'),
    );
  });
  test('does not mislabel routing and server failures as invalid PINs', () {
    expect(
      () => parseEnrollmentResponse(404, 'Not found'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Ruta'),
        ),
      ),
    );
    expect(
      () => parseEnrollmentResponse(500, 'SECRET'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('HTTP 500'),
        ),
      ),
    );
    expect(
      () => parseEnrollmentResponse(429, '{}'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('10 minute'),
        ),
      ),
    );
    expect(
      () => parseEnrollmentResponse(400, '{}'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('PIN invalid'),
        ),
      ),
    );
  });
  test('accepts a complete enrollment and rejects malformed successes', () {
    final data = {
      'token': 'fixture-token',
      'device_id': 'device',
      'location_id': 'location',
    };
    expect(parseEnrollmentResponse(200, jsonEncode(data)), data);
    for (final body in ['not-json', '{}', '{"token":""}', '[]']) {
      expect(() => parseEnrollmentResponse(200, body), throwsFormatException);
    }
  });
}
