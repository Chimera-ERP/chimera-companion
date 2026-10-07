import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/app_updates.dart';

void main() {
  final erp = Uri.parse('https://erp.example.com');
  final hash = List.filled(64, 'a').join();
  Map<String, dynamic> manifest() => {'version': 1, 'packageName': 'ro.tabusociety.chimera_companion', 'versionCode': 2, 'versionName': '0.1.1', 'size': 100, 'sha256': hash, 'path': '/api/companion-updates/$hash.apk'};
  test('accepts versioned same-origin immutable APK', () {
    expect(CompanionRelease(manifest(), erp).url.host, 'erp.example.com');
  });
  for (final mutation in [
    {'path': 'https://evil.example/app.apk'}, {'path': 'http://erp.example.com/app.apk'},
    {'path': '/api/companion-updates/$hash.apk?redirect=evil'}, {'sha256': '../key'},
    {'packageName': 'other'}, {'size': 300 * 1024 * 1024}, {'size': 0}, {'versionCode': 0},
  ]) {
    test('rejects invalid release $mutation', () {
      expect(() => CompanionRelease({...manifest(), ...mutation}, erp), throwsFormatException);
    });
  }
}
