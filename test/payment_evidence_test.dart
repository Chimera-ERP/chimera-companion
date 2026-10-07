import 'dart:convert';
import 'dart:io';
import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'operator_session_integration_test.dart' as crypto_fixture;

void main() {
  test(
    'cross-Companion evidence binds tenant, sale, destination, amount and currency',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'payment-evidence-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final payment = CryptoUtils.generateEcKeyPair(),
          receipt = CryptoUtils.generateEcKeyPair();
      final session = OfflineSession(
        file: File('${directory.path}/trust.json'),
        org: 'org',
        location: 'location',
        companion: 'ecr',
      identity: crypto_fixture.Identity(
        crypto_fixture.jwk(receipt.publicKey as ECPublicKey),
        ),
      );
      await session.restore();
      await session.updateTrust({
        'signing_keys': [],
        'peers': [],
        'equipment': [
          {
            'kind': 'payment',
            'companion_id': 'viva',
          'public_jwk': crypto_fixture.jwk(payment.publicKey as ECPublicKey),
          },
        ],
      });
      final value = {
        'org': 'org',
        'location': 'location',
        'paymentCompanion': 'viva',
        'receiptCompanion': 'ecr',
        'receiptCommandId': 'sale',
        'saleId': 'sale',
        'paymentCommandId': 'payment',
        'amountMinor': 2000,
        'currency': 'RON',
        'reference': 'terminal-reference',
        'outcome': 'succeeded',
      };
      final payload = {
        'saleId': 'sale',
        'paymentCommandId': 'payment',
        'totalMinor': 2000,
        'currency': 'RON',
      };
      String signature(String message) =>
        crypto_fixture.sign(payment.privateKey as ECPrivateKey, message);
      final message = jsonEncode(value);
      expect(
        session.verifyPayment(message, signature(message), 'sale', payload),
        'terminal-reference',
      );
      for (final change in [
        {'org': 'other'},
        {'location': 'other'},
        {'saleId': 'other'},
        {'receiptCompanion': 'other'},
        {'receiptCommandId': 'other'},
        {'amountMinor': 2001},
        {'currency': 'USD'},
        {'outcome': 'unknown'},
        {'paymentCommandId': 'other'},
      ]) {
        final altered = jsonEncode({...value, ...change});
        expect(
          () => session.verifyPayment(
            altered,
            signature(altered),
            'sale',
            payload,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => session.verifyPayment(
          message,
        crypto_fixture.sign(receipt.privateKey as ECPrivateKey, message),
          'sale',
          payload,
        ),
        throwsFormatException,
      );
      await session.updateTrust({
        'signing_keys': [],
        'peers': [],
        'equipment': [],
      });
      expect(
        () =>
            session.verifyPayment(message, signature(message), 'sale', payload),
        throwsFormatException,
      );
    },
  );
}
