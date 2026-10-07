import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/device_credentials.dart';
import 'package:chimera_companion/security/device_identity.dart';

class TestIdentity extends DeviceIdentity {
  @override
  Future<Map<String, dynamic>> publicKey() async => {
    'kty': 'EC',
    'crv': 'P-256',
  };
  @override
  Future<String> sign(String message) async => 'proof';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'renewal preserves identity, organization, location and bounded expiry',
    () {
      final now = DateTime.utc(2026, 10, 3);
      final claims = <String, dynamic>{
        'device_id': 'companion-1',
        'sub': 'companion-1',
        'org': 'org-1',
        'aud': 'org',
        'iss': 'auth',
        'role': 'companion',
        'locations': [
          {'id': 'location-1', 'name': 'Copou'},
        ],
        'exp': now.millisecondsSinceEpoch ~/ 1000 + 86400,
      };
      String token(Map<String, dynamic> value) =>
          'header.${base64UrlEncode(utf8.encode(jsonEncode(value)))}.signature';
      final previous = token(claims);
      validateRenewedDeviceToken(
        previous,
        token(claims),
        'companion-1',
        now: now,
      );
      for (final change in [
        {'org': 'org-2'},
        {'device_id': 'other'},
        {
          'locations': [
            {'id': 'other'},
          ],
        },
        {'role': 'device'},
        {'exp': 0},
        {'exp': (claims['exp'] as int) + 86400},
      ]) {
        expect(
          () => validateRenewedDeviceToken(
            previous,
            token({...claims, ...change}),
            'companion-1',
            now: now,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'retry after response loss or restart reuses attempt and renews nonce',
    () async {
      final first = await enrollmentProof(
        Uri.parse('https://erp.example.test'),
        '123456',
        identity: TestIdentity(),
      );
      final second = await enrollmentProof(
        Uri.parse('https://erp.example.test'),
        '123456',
        identity: TestIdentity(),
      );
      final a = jsonDecode(first['message'] as String),
          b = jsonDecode(second['message'] as String);
      expect(a['enrollment_id'], b['enrollment_id']);
      expect(a['nonce'], isNot(b['nonce']));
      expect(
        a['enrollment_id'],
        matches(
          RegExp(
            r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
          ),
        ),
      );
      final third = await enrollmentProof(
        Uri.parse('https://erp.example.test'),
        '654321',
        identity: TestIdentity(),
      );
      expect(
        jsonDecode(third['message'] as String)['enrollment_id'],
        isNot(a['enrollment_id']),
      );
    },
  );
}
