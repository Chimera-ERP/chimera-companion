import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/security/device_identity.dart';
import 'package:chimera_companion/security/offline_session.dart';

class TestIdentity extends DeviceIdentity {
  TestIdentity(this.key);
  final Map<String, dynamic> key;
  @override
  Future<Map<String, dynamic>> publicKey() async => key;
  @override
  Future<String> sign(String message) async => 'test-signature';
}

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/offline-jwt.json').readAsStringSync())
          as Map<String, dynamic>;
  late Directory directory;
  late OfflineSession session;
  var now = DateTime.fromMillisecondsSinceEpoch(1790000010000);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-auth-test-');
    now = DateTime.fromMillisecondsSinceEpoch(1790000010000);
    // JWK member order must not change the identity.
    final device = fixture['device'] as Map<String, dynamic>;
    session = OfflineSession(
      file: File('${directory.path}/trust.json'),
      org: 'org',
      location: 'location',
      companion: 'companion',
      identity: TestIdentity({
        'crv': device['crv'],
        'y': device['y'],
        'x': device['x'],
        'kty': device['kty'],
      }),
      now: () => now,
    );
    await session.restore();
    await session.updateTrust({
      'signing_keys': [fixture['authority']],
      'peers': [
        {'pos_id': 'pos', 'version': 1, 'revoked': false},
      ],
    });
  });
  tearDown(() async => directory.delete(recursive: true));
  test(
    'signed pairing accepts equivalent keys and issues distinct challenges',
    () async {
      final first = await session.challenge(fixture['token']);
      final second = await session.challenge(fixture['token']);
      expect(first['message'], isNot(second['message']));
      expect(jsonDecode(first['message'] as String)['companion'], 'companion');
    },
  );
  test('copied lease without client signature cannot dispatch', () async {
    final challenge = await session.challenge(fixture['token']);
    final nonce = jsonDecode(challenge['message'] as String)['challenge'];
    await expectLater(
      session.authorize({
        'lease': fixture['token'],
        'message': jsonEncode({
          'challenge': nonce,
          'companion': 'companion',
          'method': 'POST',
          'origin': 'https://pos.example',
          'commandId': 'id',
          'operation': 'status',
        }),
        'signature': fixture['signature'],
        'payloadJson': '{}',
      }, 'https://pos.example'),
      throwsFormatException,
    );
  });
  test('revocation persists and denies a previously valid lease', () async {
    await session.revokeLocally('pos');
    await session.restore();
    await expectLater(
      session.challenge(fixture['token']),
      throwsFormatException,
    );
  });
  test('authorization expires and clock rollback is rejected', () async {
    await session.challenge(fixture['token']);
    now = now.subtract(const Duration(minutes: 1));
    await expectLater(session.challenge(fixture['token']), throwsStateError);
    now = DateTime.fromMillisecondsSinceEpoch(
      1790000010000,
    ).add(const Duration(days: 7));
    await expectLater(
      session.challenge(fixture['token']),
      throwsFormatException,
    );
  });
}
