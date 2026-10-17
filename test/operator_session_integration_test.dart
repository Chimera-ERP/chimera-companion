import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/security/device_identity.dart';
import 'package:chimera_companion/security/offline_session.dart';

String b64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
List<int> integer(BigInt value) {
  final hex = value.toRadixString(16).padLeft(64, '0');
  return [
    for (var i = 0; i < 64; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

Map<String, dynamic> jwk(ECPublicKey key) => {
  'kty': 'EC',
  'crv': 'P-256',
  'x': b64(integer(key.Q!.x!.toBigInteger()!)),
  'y': b64(integer(key.Q!.y!.toBigInteger()!)),
};
String sign(ECPrivateKey key, String message) {
  final value = CryptoUtils.ecSign(
    key,
    Uint8List.fromList(utf8.encode(message)),
    algorithmName: 'SHA-256/ECDSA',
  );
  return b64([...integer(value.r), ...integer(value.s)]);
}

class Identity extends DeviceIdentity {
  Identity(this.key);
  final Map<String, dynamic> key;
  @override
  Future<Map<String, dynamic>> publicKey() async => key;
  @override
  Future<String> sign(String message) async => 'unused-result-signature';
}

void main() {
  test(
    'operator proof creates restart-safe session; replay, revocation and expiry fail closed',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'operator-session-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final issuer = CryptoUtils.generateEcKeyPair(),
          pos = CryptoUtils.generateEcKeyPair();
      final companion = CryptoUtils.generateEcKeyPair(),
          passkey = CryptoUtils.generateEcKeyPair();
      var now = DateTime.utc(2026, 10, 3);
      final start = now.millisecondsSinceEpoch ~/ 1000;
      final base = <String, dynamic>{
        'iss': 'chimera-companion',
        'org': 'org',
        'location': 'location',
        'aud': 'companion',
        'companion': 'companion',
        'pos': 'pos',
        'version': 1,
        'iat': start,
        'nbf': start,
        'exp': start + 7 * 86400,
        'operations': ['nonFiscal'],
        'cnf': {'jwk': jwk(pos.publicKey as ECPublicKey)},
        'peer': {'jwk': jwk(companion.publicKey as ECPublicKey)},
      };
      String token(Map<String, dynamic> claims) {
        final content =
            '${b64(utf8.encode(jsonEncode({'alg': 'ES256', 'typ': 'JWT', 'kid': 'issuer'})))}.${b64(utf8.encode(jsonEncode(claims)))}';
        return '$content.${sign(issuer.privateKey as ECPrivateKey, content)}';
      }

      final lease = token({...base, 'kind': 'pair', 'sub': 'pos'});
      final pem = CryptoUtils.encodeEcPublicKeyToPem(
        passkey.publicKey as ECPublicKey,
      );
      final spki = base64Decode(
        pem.replaceAll(RegExp(r'-----[^\n]+-----|\s'), ''),
      );
      final operator = token({
        ...base,
        'kind': 'operator',
        'sub': 'operator',
        'operatorName': 'Test',
        'webauthn': {
          'origin': 'https://pos.example.test',
          'rpId': 'example.test',
          'credentials': [
            {
              'id': 'credential',
              'publicKey': b64(spki),
              'algorithm': -7,
              'counter': 0,
            },
          ],
        },
      });
      OfflineSession create() => OfflineSession(
        file: File('${directory.path}/trust.json'),
        org: 'org',
        location: 'location',
        companion: 'companion',
        identity: Identity(jwk(companion.publicKey as ECPublicKey)),
        now: () => now,
      );
      var session = create();
      await session.restore();
      final trust = {
        'signing_keys': [
          {...jwk(issuer.publicKey as ECPublicKey), 'kid': 'issuer'},
        ],
        'peers': [
          {'pos_id': 'pos', 'version': 1, 'revoked': false},
        ],
      };
      await session.updateTrust(trust);
      Future<Map<String, dynamic>> command({
        String? sessionId,
        bool assertion = false,
        String? loginProof,
        Map<String, dynamic>? posEvidence,
      }) async {
        final challenge =
            jsonDecode(
                  (await session.challenge(lease))['message'] as String,
                )['challenge']
                as String;
        const payload = '{"lines":["test"]}';
        final message = jsonEncode({
          'challenge': challenge,
          'companion': 'companion',
          'method': 'POST',
          'origin': 'https://pos.example.test',
          'commandId': 'command-$challenge',
          'operation': 'nonFiscal',
          'payloadHash': sha256.convert(utf8.encode(payload)).toString(),
          'operatorSession': ?sessionId,
          if (posEvidence != null)
            'posSessionHash': sha256
                .convert(utf8.encode(jsonEncode(posEvidence)))
                .toString(),
        });
        final body = <String, dynamic>{
          'lease': lease,
          'operatorGrant': operator,
          'message': message,
          'signature': sign(pos.privateKey as ECPrivateKey, message),
          'payloadJson': payload,
          'operatorLoginProof': ?loginProof,
          'posOperatorSession': ?posEvidence,
        };
        if (assertion) {
          final client = utf8.encode(
            jsonEncode({
              'type': 'webauthn.get',
              'challenge': challenge,
              'origin': 'https://pos.example.test',
              'crossOrigin': false,
            }),
          );
          final auth = [
            ...sha256.convert(utf8.encode('example.test')).bytes,
            5,
            0,
            0,
            0,
            0,
          ];
          final signature = CryptoUtils.ecSign(
            passkey.privateKey as ECPrivateKey,
            Uint8List.fromList([...auth, ...sha256.convert(client).bytes]),
            algorithmName: 'SHA-256/ECDSA',
          );
          body['operatorAssertion'] = {
            'id': 'credential',
            'response': {
              'authenticatorData': b64(auth),
              'clientDataJSON': b64(client),
              'signature': b64(
                base64Decode(CryptoUtils.ecSignatureToBase64(signature)),
              ),
            },
          };
        }
        return body;
      }

      final loginClaims = {
        ...base,
        'kind': 'operator_login',
        'sub': 'operator',
        'credential': 'credential',
        'origin': 'https://pos.example.test',
        'exp': start + 300,
      };
      for (final invalid in [
        {...loginClaims, 'pos': 'other'},
        {...loginClaims, 'sub': 'other'},
        {...loginClaims, 'credential': 'revoked-or-other'},
        {...loginClaims, 'origin': 'https://other.test'},
        {...loginClaims, 'exp': start + 301},
        {...loginClaims, 'exp': start},
      ]) {
        await expectLater(
          session.authorize(
            await command(loginProof: token(invalid)),
            'https://pos.example.test',
          ),
          throwsFormatException,
        );
      }
      final proofCommand = await command(loginProof: token(loginClaims));
      final proofSession = await session.authorize(
        proofCommand,
        'https://pos.example.test',
      );
      expect(proofSession['operatorId'], 'operator');
      await expectLater(
        session.authorize(proofCommand, 'https://pos.example.test'),
        throwsFormatException,
      );
      // One POS login, reusable across commands and Companion restart, without
      // ever issuing a separate Companion operator session or passkey challenge.
      final posClaims = {
        ...loginClaims,
        'kind': 'pos_operator_login',
        'session_id': 'original-login',
        'auth_at': start,
        'exp': start + 86400,
      };
      final authorityProof = {'type': 'authority', 'token': token(posClaims)};
      final firstPos = await command(posEvidence: authorityProof);
      final firstResult = await session.authorize(
        firstPos,
        'https://pos.example.test',
      );
      expect(firstResult['operatorId'], 'operator');
      expect(firstResult.containsKey('operatorSession'), false);
      await expectLater(
        session.authorize(firstPos, 'https://pos.example.test'),
        throwsFormatException,
      );
      session = create();
      await session.restore();
      expect(
        (await session.authorize(
          await command(posEvidence: authorityProof),
          'https://pos.example.test',
        ))['operatorId'],
        'operator',
      );
      for (final invalid in [
        {...posClaims, 'pos': 'another'},
        {...posClaims, 'sub': 'another'},
        {...posClaims, 'version': 2},
        {...posClaims, 'origin': 'https://evil.test'},
        {...posClaims, 'auth_at': start - 604800},
        {...posClaims, 'credential': 'unknown'},
        {
          ...posClaims,
          'cnf': {'jwk': jwk(companion.publicKey as ECPublicKey)},
        },
      ]) {
        await expectLater(
          session.authorize(
            await command(
              posEvidence: {'type': 'authority', 'token': token(invalid)},
            ),
            'https://pos.example.test',
          ),
          throwsFormatException,
        );
      }
      final bounds = {
        'v': 1,
        'kind': 'pos_operator_session',
        'org': 'org',
        'location': 'location',
        'pos': 'pos',
        'operator': 'operator',
        'origin': 'https://pos.example.test',
        'cnf': base['cnf'],
        'iat': start,
        'exp': start + 86400,
        'nonce': b64(List<int>.filled(32, 1)),
      };
      Map<String, dynamic> offlineProof(Map<String, dynamic> scope) {
        final challenge = b64(utf8.encode(jsonEncode(scope)));
        final client = utf8.encode(
          jsonEncode({
            'type': 'webauthn.get',
            'challenge': challenge,
            'origin': 'https://pos.example.test',
            'crossOrigin': false,
          }),
        );
        final auth = [
          ...sha256.convert(utf8.encode('example.test')).bytes,
          5,
          0,
          0,
          0,
          1,
        ];
        final signature = CryptoUtils.ecSign(
          passkey.privateKey as ECPrivateKey,
          Uint8List.fromList([...auth, ...sha256.convert(client).bytes]),
          algorithmName: 'SHA-256/ECDSA',
        );
        return {
          'type': 'passkey',
          'challenge': challenge,
          'assertion': {
            'id': 'credential',
            'response': {
              'authenticatorData': b64(auth),
              'clientDataJSON': b64(client),
              'signature': b64(
                base64Decode(CryptoUtils.ecSignatureToBase64(signature)),
              ),
            },
          },
        };
      }

      final offline = offlineProof(bounds);
      expect(
        (await session.authorize(
          await command(posEvidence: offline),
          'https://pos.example.test',
        ))['operatorId'],
        'operator',
      );
      now = now.add(const Duration(hours: 8));
      session = create();
      await session.restore();
      expect(
        (await session.authorize(
          await command(posEvidence: offline),
          'https://pos.example.test',
        ))['operatorId'],
        'operator',
      );
      expect(
        (await session.authorize(
          await command(posEvidence: authorityProof),
          'https://pos.example.test',
        ))['operatorId'],
        'operator',
      );
      for (final invalid in [
        {...bounds, 'pos': 'other'},
        {...bounds, 'operator': 'other'},
        {...bounds, 'org': 'other'},
        {...bounds, 'location': 'other'},
        {...bounds, 'origin': 'https://other.test'},
        {
          ...bounds,
          'cnf': {'jwk': jwk(companion.publicKey as ECPublicKey)},
        },
        {...bounds, 'exp': start + 604801},
        {...bounds, 'exp': start + 1},
        {...bounds, 'iat': now.millisecondsSinceEpoch ~/ 1000 + 60},
      ]) {
        await expectLater(
          session.authorize(
            await command(posEvidence: offlineProof(invalid)),
            'https://pos.example.test',
          ),
          throwsFormatException,
        );
      }
      final changed = await command(posEvidence: offline);
      changed['posOperatorSession'] = authorityProof;
      await expectLater(
        session.authorize(changed, 'https://pos.example.test'),
        throwsFormatException,
      );
      await session.updateTrust({
        ...trust,
        'revoked_credentials': ['credential'],
      });
      for (final evidence in [authorityProof, offline]) {
        await expectLater(
          session.authorize(
            await command(posEvidence: evidence),
            'https://pos.example.test',
          ),
          throwsFormatException,
        );
      }
      await session.updateTrust(trust);
      final first = await command(assertion: true);
      final authorized = await session.authorize(
        first,
        'https://pos.example.test',
      );
      final sessionId = authorized['operatorSession'] as String;
      await expectLater(
        session.authorize(first, 'https://pos.example.test'),
        throwsFormatException,
      );
      session = create();
      await session.restore();
      expect(
        (await session.authorize(
          await command(sessionId: sessionId),
          'https://pos.example.test',
        ))['operatorId'],
        'operator',
      );
      await session.updateTrust({
        ...trust,
        'revoked_credentials': ['credential'],
      });
      await expectLater(
        session.authorize(
          await command(sessionId: sessionId),
          'https://pos.example.test',
        ),
        throwsFormatException,
      );
      await session.updateTrust(trust);
      now = now.add(const Duration(hours: 8));
      await expectLater(
        session.authorize(
          await command(sessionId: sessionId),
          'https://pos.example.test',
        ),
        throwsFormatException,
      );
    },
  );
}
