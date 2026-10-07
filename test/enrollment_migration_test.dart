import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/enrollment.dart';

void main() {
  test(
    'legacy completed setup without valid ERP pairing returns to wizard',
    () {
      expect(hasSavedEnrollment(null), false);
      expect(hasSavedEnrollment('{}'), false);
      expect(hasSavedEnrollment('corrupt'), false);
      final data = {
        'token': 'credential',
        'device_id': 'device',
        'location_id': 'location',
        'erp_url': 'https://erp.example.test',
      };
      expect(hasSavedEnrollment(jsonEncode(data)), true);
      expect(
        hasSavedEnrollment(
          jsonEncode({...data, 'erp_url': 'http://erp.example.test'}),
        ),
        false,
      );
    },
  );
}
