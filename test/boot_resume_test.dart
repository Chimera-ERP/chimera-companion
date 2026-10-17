import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:forui/forui.dart';
import 'package:chimera_companion/local_bridge.dart';
import 'package:chimera_companion/main.dart';

class RecordingBridge extends LocalBridge {
  int starts = 0, closes = 0;
  bool fail = false;
  @override
  Future<void> start() async {
    starts++;
    if (fail) throw StateError('Invalid cached TLS');
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enrollment = jsonEncode({
    'token': 'fixture-token',
    'device_id': 'device',
    'location_id': 'location',
    'erp_url': 'https://erp.example',
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'resumes enrolled bridge without building a widget or contacting an Activity',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'setup_complete_v2': 'true',
        'erp_pairing_v1': enrollment,
      });
      final bridge = RecordingBridge();
      await resumeSavedCompanion(bridge);
      expect(bridge.starts, 1);
      expect(bridge.closes, 0);
    },
  );
  test('does not start incomplete or malformed enrollments', () async {
    for (final values in <Map<String, String>>[
      {},
      {'erp_pairing_v1': enrollment},
      {'setup_complete_v2': 'true'},
      {'setup_complete_v2': 'true', 'erp_pairing_v1': '{}'},
      {'setup_complete_v2': 'true', 'erp_pairing_v1': 'not-json'},
    ]) {
      FlutterSecureStorage.setMockInitialValues(values);
      final bridge = RecordingBridge();
      await resumeSavedCompanion(bridge);
      expect(bridge.starts, 0);
    }
  });
  test(
    'an unavailable configuration is recoverable, without uncaught boot errors',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'setup_complete_v2': 'true',
        'erp_pairing_v1': enrollment,
      });
      final bridge = RecordingBridge()..fail = true;
      await resumeSavedCompanion(bridge);
      expect(bridge.starts, 1);
      bridge.fail = false;
      await resumeSavedCompanion(bridge);
      expect(bridge.starts, 2);
    },
  );
  testWidgets('closing the UI does not stop the application-owned bridge', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) =>
            FTheme(data: FTheme.neutral.dark.touch, child: child!),
        home: CompanionHome(bridge: bridge),
      ),
    );
    await tester.pumpAndSettle();
    expect(bridge.starts, 1);
    await tester.pumpWidget(const SizedBox());
    expect(bridge.closes, 0);
    expect(tester.takeException(), isNull);
  });
}
