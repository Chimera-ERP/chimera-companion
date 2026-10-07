import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/security/offline_grant.dart';

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/offline-jwt.json').readAsStringSync())
          as Map<String, dynamic>;
  final key = fixture['authority'] as Map<String, dynamic>;
  OfflineGrantVerifier verifier({
    String org = 'org',
    String location = 'location',
    String companion = 'companion',
  }) => OfflineGrantVerifier(
    keys: {key['kid']: key},
    org: org,
    location: location,
    companion: companion,
  );
  final now = DateTime.fromMillisecondsSinceEpoch(1790000010000);
  test(
    'verifies an actual ES256 JWT produced by Chimera Node authority offline',
    () {
      final claims = verifier().verify(
        fixture['token'],
        kind: 'pair',
        now: now,
      );
      expect(claims['operations'], ['status']);
      expect(claims['exp'] - claims['iat'], offlineLeaseSeconds);
    },
  );
  test('rejects copied tokens, wrong grant kinds, expiry and tampering', () {
    for (final instance in [
      verifier(org: 'other'),
      verifier(location: 'other'),
      verifier(companion: 'other'),
    ]) {
      expect(
        () => instance.verify(fixture['token'], kind: 'pair', now: now),
        throwsFormatException,
      );
    }
    expect(
      () => verifier().verify(fixture['token'], kind: 'operator', now: now),
      throwsFormatException,
    );
    expect(
      () => verifier().verify(
        fixture['token'],
        kind: 'pair',
        now: now.add(const Duration(days: 7)),
      ),
      throwsFormatException,
    );
    final parts = (fixture['token'] as String).split('.');
    final claims =
        jsonDecode(utf8.decode(decodeBase64Url(parts[1])))
            as Map<String, dynamic>;
    claims['operations'] = ['rawCommand'];
    parts[1] = base64Url
        .encode(utf8.encode(jsonEncode(claims)))
        .replaceAll('=', '');
    expect(
      () => verifier().verify(parts.join('.'), kind: 'pair', now: now),
      throwsFormatException,
    );
  });
  test('verifies device proof and refuses changed command payload', () {
    expect(
      verifier().verifySignature(
        fixture['device'],
        fixture['message'],
        fixture['signature'],
      ),
      isTrue,
    );
    expect(
      verifier().verifySignature(
        fixture['device'],
        '${fixture['message']} altered',
        fixture['signature'],
      ),
      isFalse,
    );
  });
  test('clock high-water prevents rollback and survives restoration', () {
    final clock = AuthorizationClock();
    expect(clock.check(now), now);
    expect(clock.check(now.subtract(const Duration(seconds: 2))), now);
    final restored = AuthorizationClock(highWater: clock.highWater);
    expect(
      () => restored.check(now.subtract(const Duration(minutes: 1))),
      throwsStateError,
    );
  });
}
