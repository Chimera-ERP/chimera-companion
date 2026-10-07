import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:chimera_companion/security/operator_assertion.dart';

void main() {
  final pair = CryptoUtils.generateEcKeyPair();
  final pem = CryptoUtils.encodeEcPublicKeyToPem(pair.publicKey as ECPublicKey);
  final encoded = pem.replaceAll(RegExp(r'-----[^\n]+-----|\s'), '');
  final credential = {
    'id': 'credential',
    'publicKey': base64UrlEncode(base64Decode(encoded)).replaceAll('=', ''),
    'algorithm': -7,
  };
  final policy = {'origin': 'https://pos.example.test', 'rpId': 'example.test'};
  String b64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
  Map<String, dynamic> assertion({
    int counter = 0,
    int flags = 5,
    String challenge = 'challenge',
  }) {
    final client = utf8.encode(
      jsonEncode({
        'type': 'webauthn.get',
        'challenge': challenge,
        'origin': policy['origin'],
        'crossOrigin': false,
      }),
    );
    final number = ByteData(4)..setUint32(0, counter);
    final auth = [
      ...sha256.convert(utf8.encode(policy['rpId']!)).bytes,
      flags,
      ...number.buffer.asUint8List(),
    ];
    final signature = CryptoUtils.ecSign(
      pair.privateKey as ECPrivateKey,
      Uint8List.fromList([...auth, ...sha256.convert(client).bytes]),
      algorithmName: 'SHA-256/ECDSA',
    );
    return {
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

  test('verified user assertion accepts counterless synced passkey', () {
    expect(
      verifyOperatorAssertion(
        assertion(),
        credential,
        policy,
        'challenge',
        policy['origin']!,
        0,
      ),
      0,
    );
    expect(
      verifyOperatorAssertion(
        assertion(counter: 2),
        credential,
        policy,
        'challenge',
        policy['origin']!,
        1,
      ),
      2,
    );
  });
  test(
    'rejects absent UV, foreign RP/origin/challenge and signature replay',
    () {
      for (final flags in [0, 1, 4]) {
        expect(
          () => verifyOperatorAssertion(
            assertion(flags: flags),
            credential,
            policy,
            'challenge',
            policy['origin']!,
            0,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => verifyOperatorAssertion(
          assertion(),
          credential,
          policy,
          'other',
          policy['origin']!,
          0,
        ),
        throwsFormatException,
      );
      expect(
        () => verifyOperatorAssertion(
          assertion(),
          credential,
          policy,
          'challenge',
          'https://evil.example.test',
          0,
        ),
        throwsFormatException,
      );
      expect(
        () => verifyOperatorAssertion(
          assertion(),
          credential,
          {...policy, 'rpId': 'other.test'},
          'challenge',
          policy['origin']!,
          0,
        ),
        throwsFormatException,
      );
      expect(
        () => verifyOperatorAssertion(
          assertion(counter: 1),
          credential,
          policy,
          'challenge',
          policy['origin']!,
          1,
        ),
        throwsFormatException,
      );
      final modified = assertion();
      (modified['response'] as Map)['signature'] = b64(List<int>.filled(64, 0));
      expect(
        () => verifyOperatorAssertion(
          modified,
          credential,
          policy,
          'challenge',
          policy['origin']!,
          0,
        ),
        throwsA(anything),
      );
    },
  );
}
