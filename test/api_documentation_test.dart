import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local contract names every allowed business operation and signing paths', () {
    final source = File('lib/local_bridge.dart').readAsStringSync();
    final declaration = RegExp(r'const companionOperations = \[([\s\S]*?)\];').firstMatch(source)!;
    final operations = RegExp("'([^']+)'").allMatches(declaration.group(1)!).map((match) => match.group(1)!);
    final document = File('docs/api.md').readAsStringSync();
    for (final operation in operations) {
      expect(document, contains('`$operation`'), reason: 'Missing local operation $operation');
    }
    expect(document, contains('POST /v2/challenge'));
    expect(document, contains('POST /v1/commands'));
    expect(document, contains('32768-byte'));
    expect(document, contains('legacy tickets are rejected'));
  });
}
