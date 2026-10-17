import 'dart:convert';
import 'dart:io';
import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'operator_session_integration_test.dart' show b64, jwk, sign, Identity;

void main() {
  test(
    'display authorization binds operation, payload and POS without operator grants',
    () async {
      final dir = await Directory.systemTemp.createTemp('display-auth-');
      addTearDown(() => dir.delete(recursive: true));
      final authority = CryptoUtils.generateEcKeyPair(),
          pos = CryptoUtils.generateEcKeyPair(),
          companion = CryptoUtils.generateEcKeyPair();
      final now = DateTime.utc(2026, 10, 14),
          start = DateTime.utc(2026, 10, 14).millisecondsSinceEpoch ~/ 1000;
      final claims = {
        'iss': 'chimera-companion',
        'kind': 'pair',
        'org': 'org',
        'location': 'location',
        'aud': 'companion',
        'companion': 'companion',
        'pos': 'pos',
        'sub': 'pos',
        'version': 1,
        'iat': start,
        'nbf': start,
        'exp': start + 86400,
        'operations': ['customerDisplay'],
        'cnf': {'jwk': jwk(pos.publicKey as ECPublicKey)},
        'peer': {'jwk': jwk(companion.publicKey as ECPublicKey)},
      };
      final tokenBody =
          '${b64(utf8.encode(jsonEncode({'alg': 'ES256', 'typ': 'JWT', 'kid': 'issuer'})))}.${b64(utf8.encode(jsonEncode(claims)))}';
      final lease =
          '$tokenBody.${sign(authority.privateKey as ECPrivateKey, tokenBody)}';
      final session = OfflineSession(
        file: File('${dir.path}/trust.json'),
        org: 'org',
        location: 'location',
        companion: 'companion',
        identity: Identity(jwk(companion.publicKey as ECPublicKey)),
        now: () => now,
      );
      await session.restore();
      await session.updateTrust({
        'signing_keys': [
          {...jwk(authority.publicKey as ECPublicKey), 'kid': 'issuer'},
        ],
        'peers': [
          {'pos_id': 'pos', 'version': 1, 'revoked': false},
        ],
      });
      Future<Map<String, dynamic>> envelope(String operation) async {
        final nonce = jsonDecode(
          (await session.challenge(lease))['message'] as String,
        )['challenge'];
        const payload =
            '{"revision":1,"currency":"RON","totalMinor":0,"lines":[]}';
        final message = jsonEncode({
          'companion': 'companion',
          'method': 'POST',
          'origin': 'https://pos.example',
          'commandId': 'display-$nonce',
          'challenge': nonce,
          'operation': operation,
          'payloadHash': sha256.convert(utf8.encode(payload)).toString(),
        });
        return {
          'lease': lease,
          'message': message,
          'signature': sign(pos.privateKey as ECPrivateKey, message),
          'payloadJson': payload,
        };
      }

      final request = await envelope('customerDisplay');
      await expectLater(
        session.authorize({
          ...request,
          'signature': sign(
            companion.privateKey as ECPrivateKey,
            request['message'],
          ),
        }, 'https://pos.example'),
        throwsFormatException,
      );
      await expectLater(
        session.authorize({
          ...request,
          'payloadJson': '{}',
        }, 'https://pos.example'),
        throwsFormatException,
      );
      final proof = await session.authorize(request, 'https://pos.example');
      expect(proof['pos'], 'pos');
      expect(proof['operatorId'], isNull);
      await expectLater(
        session.authorize(request, 'https://pos.example'),
        throwsFormatException,
      );
      await expectLater(
        session.authorize(
          await envelope('fiscalReceipt'),
          'https://pos.example',
        ),
        throwsFormatException,
      );
    },
  );
}
