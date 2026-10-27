import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/local_bridge.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/fiscal_device.dart';
import 'package:chimera_companion/security/device_identity.dart';
import 'package:chimera_companion/security/offline_grant.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'tls_fixture.dart';
import 'adapters_test.dart' as fixtures;

class NetworkTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class BridgeFiscalFixture extends FiscalDevice {
  BridgeFiscalFixture() : super(fixtures.connection());
  int prints = 0;
  bool offline = false;
  CommandOutcome outcome = CommandOutcome.succeeded;
  @override
  Future<DeviceStatus> readStatus() async => DeviceStatus(
    ready: !offline,
    description: offline ? 'Offline' : 'Fixture ready',
  );
  @override
  Future<bool> operatorReady(
    Map<String, dynamic> identity,
    Future<Map<String, dynamic>?> Function(String) read,
  ) async => !offline;
  @override
  Future<Map<String, double>> readVatRates() async => {'1': 21};
  @override
  Future<HardwareResult> receipt(FiscalReceipt receipt) async {
    prints++;
    return HardwareResult(
      outcome,
      reference: 'receipt-7',
      message: 'Fixture hardware result',
    );
  }
}

// Ephemeral synthetic keys. Real production DeviceIdentity uses Android/iOS
// keystore; this fixture does not access a phone, bank or fiscal device.
class SigningFixture extends DeviceIdentity {
  SigningFixture(int value) : secret = BigInt.from(value);
  final BigInt secret;
  final domain = ECDomainParameters('prime256v1');
  Uint8List bytes(BigInt value) => Uint8List.fromList(
    List.generate(
      32,
      (i) => ((value >> (8 * (31 - i))) & BigInt.from(255)).toInt(),
    ),
  );
  Map<String, dynamic> get jwk {
    final point = (domain.G * secret)!;
    return {
      'kty': 'EC',
      'crv': 'P-256',
      'x': base64UrlEncode(bytes(point.x!.toBigInteger()!)),
      'y': base64UrlEncode(bytes(point.y!.toBigInteger()!)),
    };
  }

  String signature(String message) {
    final random = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i + 1))));
    final signer = ECDSASigner(SHA256Digest())
      ..init(
        true,
        ParametersWithRandom(
          PrivateKeyParameter(ECPrivateKey(secret, domain)),
          random,
        ),
      );
    final value =
        signer.generateSignature(Uint8List.fromList(utf8.encode(message)))
            as ECSignature;
    return base64UrlEncode([...bytes(value.r), ...bytes(value.s)]);
  }

  String token(Map<String, dynamic> claims) {
    String encode(Object value) =>
        base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final message =
        '${encode({'alg': 'ES256', 'typ': 'JWT', 'kid': 'fixture-authority'})}.${encode(claims)}';
    return '$message.${signature(message)}';
  }

  @override
  Future<Map<String, dynamic>> publicKey() async => jwk;
  @override
  Future<String> sign(String message) async => signature(message);
}

void main() {
  NetworkTestBinding();
  for (final receiptOutcome in [
    CommandOutcome.succeeded,
    CommandOutcome.unknown,
  ]) {
    test(
      'signed HTTPS external-card flow persists ${receiptOutcome.name} receipt after bridge restart',
      () async {
        final tls = await TlsFixture.create();
        FlutterSecureStorage.setMockInitialValues({'local_hardware_v1': '{"host":"192.168.1.25"}'});
        final authority = SigningFixture(17),
            pos = SigningFixture(18),
            companion = SigningFixture(19);
        final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final session = OfflineSession(
          file: File('${tls.directory.path}/bridge-trust'),
          org: 'org',
          location: 'copou',
          companion: 'ecr',
          identity: companion,
        );
        await session.restore();
        await session.updateTrust({
          'signing_keys': [
            {...authority.jwk, 'kid': 'fixture-authority'},
          ],
          'peers': [
            {'pos_id': 'pos', 'version': 1, 'revoked': false},
          ],
          'equipment': [
            {
              'kind': 'ecr',
              'companion_id': 'ecr',
              'host': '192.168.1.20',
              'port': 9100,
              'public_jwk': companion.jwk,
            },
          ],
        });
        final operations = [
          'saleAuthorize',
          'saleExternalPaymentConfirm',
          'fiscalReceipt',
        ];
        final base = {
          'iss': 'chimera-companion',
          'org': 'org',
          'location': 'copou',
          'aud': 'ecr',
          'companion': 'ecr',
          'pos': 'pos',
          'version': 1,
          'iat': seconds,
          'nbf': seconds,
          'exp': seconds + 600,
          'operations': operations,
          'cnf': {'jwk': pos.jwk},
        };
        final lease = authority.token({
          ...base,
          'kind': 'pair',
          'sub': 'pos',
          'peer': {'jwk': companion.jwk},
        });
        final operator = authority.token({
          ...base,
          'kind': 'operator',
          'sub': 'alice',
          'operatorName': 'Alice',
          'checkoutPolicy': {'card_mode': 'external'},
          'webauthn': {
            'origin': 'https://pos.example',
            'credentials': [
              {'id': 'credential', 'counter': 0},
            ],
          },
        });
        final login = authority.token({
          ...base,
          'kind': 'operator_login',
          'sub': 'alice',
          'origin': 'https://pos.example',
          'credential': 'credential',
          'exp': seconds + 120,
        });
        final device = BridgeFiscalFixture()..outcome = receiptOutcome;
        final journal = File('${tls.directory.path}/bridge-journal');
        LocalBridge createBridge() =>
            LocalBridge(
                journal: CommandJournal(journal),
                security: session,
                deviceFactory: (_) => device,
              )
              ..companionId = 'ecr'
              ..locationId = 'copou';
        var bridge = createBridge();
        final server = CompanionServer(
          verify: (_) async => throw StateError('No legacy auth'),
          security: session,
          run: (operation, id, payload) => bridge.run(operation, id, payload),
        );
        final client = HttpClient(context: tls.clientContext);
        final verifier = OfflineGrantVerifier(
          keys: {},
          org: 'org',
          location: 'copou',
          companion: 'ecr',
        );
        try {
          await server.start(
            securityContext: tls.serverContext,
            address: InternetAddress.loopbackIPv4,
            port: 0,
          );
          Future<(int, Map<String, dynamic>)> send(
            String path,
            Map<String, dynamic> body,
          ) async {
            final request = await client.postUrl(
              Uri.parse('https://127.0.0.1:${server.port}$path'),
            );
            request.headers.set('Origin', 'https://pos.example');
            request.headers.contentType = ContentType.json;
            request.write(jsonEncode(body));
            final response = await request.close();
            return (
              response.statusCode,
              jsonDecode(await utf8.decoder.bind(response).join())
                  as Map<String, dynamic>,
            );
          }

          Future<(int, Map<String, dynamic>)> command(
            String operation,
            String id,
            Map<String, dynamic> payload,
          ) async {
            final challenge = await send('/v2/challenge', {'lease': lease});
            expect(challenge.$1, 200);
            final json = jsonEncode(payload);
            final message = jsonEncode({
              'challenge': jsonDecode(challenge.$2['message'])['challenge'],
              'companion': 'ecr',
              'method': 'POST',
              'origin': 'https://pos.example',
              'commandId': id,
              'operation': operation,
              'payloadHash': sha256.convert(utf8.encode(json)).toString(),
            });
            return send('/v1/commands', {
              'lease': lease,
              'operatorGrant': operator,
              'operatorLoginProof': login,
              'message': message,
              'signature': pos.signature(message),
              'payloadJson': json,
            });
          }

          final facts = {
            'currency': 'RON',
            'paymentMethod': 'card',
            'totalMinor': 500,
            'lines': [
              {
                'name': 'Coffee',
                'quantity': '1',
                'unitPriceMinor': 500,
                'grossTotalMinor': 500,
                'vatRate': 21,
              },
            ],
          };
          final authorized = await command('saleAuthorize', 'sale', {
            'saleId': 'sale',
            'receiptJson': jsonEncode(facts),
            'lifecycleVersion': 1,
          });
          expect(authorized.$1, 200);
          expect(
            verifier.verifySignature(
              companion.jwk,
              authorized.$2['resultJson'],
              authorized.$2['signature'],
            ),
            isTrue,
          );
          final admission = jsonDecode(
            authorized.$2['resultJson'],
          )['saleAdmission'];
          expect(admission['phase'], 'admitted');
          final receiptPayload = <String, dynamic>{
            ...facts,
            'saleId': 'sale',
            'saleAuthorization': authorized.$2,
            'externalPaymentConfirmation': {
              'saleId': 'sale',
              'operatorId': 'alice',
              'amountMinor': 500,
              'currency': 'RON',
              'confirmed': true,
            },
          };
          expect(
            (await command('fiscalReceipt', 'sale', receiptPayload)).$1,
            409,
          );
          expect(device.prints, 0);
          final confirmed = await command(
            'saleExternalPaymentConfirm',
            'sale-external-confirm',
            {
              'saleId': 'sale',
              'amountMinor': 500,
              'currency': 'RON',
              'confirmed': true,
            },
          );
          expect(confirmed.$1, 200);
          expect(
            jsonDecode(confirmed.$2['resultJson'])['saleAdmission']['phase'],
            'external_confirmed',
          );
          final printed = await command(
            'fiscalReceipt',
            'sale',
            receiptPayload,
          );
          expect(printed.$1, 200);
          expect(
            jsonDecode(printed.$2['resultJson'])['outcome'],
            receiptOutcome.name,
          );
          expect(device.prints, 1);
          // Lose the original result in the client and recreate only the bridge.
          // The durable journal and secure-storage fixture survive this restart.
          await bridge.close();
          device.offline = true;
          bridge = createBridge();
          final recovered = await command(
            'fiscalReceipt',
            'sale',
            receiptPayload,
          );
          expect(recovered.$1, 200);
          expect(
            verifier.verifySignature(
              companion.jwk,
              recovered.$2['resultJson'],
              recovered.$2['signature'],
            ),
            isTrue,
          );
          expect(
            jsonDecode(recovered.$2['resultJson'])['outcome'],
            receiptOutcome.name,
          );
          expect(device.prints, 1);
          expect(
            await CommandJournal(journal).hasUnresolvedDrawerEffects(device.id),
            receiptOutcome == CommandOutcome.unknown,
          );
        } finally {
          client.close(force: true);
          await server.close();
          await bridge.close();
          await tls.directory.delete(recursive: true);
        }
      },
    );
  }
  test(
    'real ES256 grants and POS proof authorize HTTPS operations without replay or payload override',
    () async {
      final tls = await TlsFixture.create();
      final authority = SigningFixture(7),
          pos = SigningFixture(8),
          companion = SigningFixture(9);
      final now = DateTime.utc(2026, 10, 4, 12),
          seconds =
              DateTime.utc(2026, 10, 4, 12).millisecondsSinceEpoch ~/ 1000;
      final session = OfflineSession(
        file: File('${tls.directory.path}/trust'),
        org: 'org',
        location: 'copou',
        companion: 'ecr',
        identity: companion,
        now: () => now,
      );
      await session.restore();
      await session.updateTrust({
        'signing_keys': [
          {...authority.jwk, 'kid': 'fixture-authority'},
        ],
        'peers': [
          {'pos_id': 'pos', 'version': 1, 'revoked': false},
        ],
      });
      final operations = [
        'saleAuthorize',
        'salePaymentStart',
        'saleExternalPaymentConfirm',
        'salePaymentReject',
      ];
      final base = {
        'iss': 'chimera-companion',
        'org': 'org',
        'location': 'copou',
        'aud': 'ecr',
        'companion': 'ecr',
        'pos': 'pos',
        'version': 1,
        'iat': seconds,
        'nbf': seconds,
        'exp': seconds + 600,
        'operations': operations,
        'cnf': {'jwk': pos.jwk},
      };
      final lease = authority.token({
        ...base,
        'kind': 'pair',
        'sub': 'pos',
        'peer': {'jwk': companion.jwk},
      });
      final operator = authority.token({
        ...base,
        'kind': 'operator',
        'sub': 'alice',
        'operatorName': 'Alice',
        'checkoutPolicy': {'card_mode': 'external'},
        'webauthn': {
          'origin': 'https://pos.example',
          'credentials': [
            {'id': 'credential', 'counter': 0},
          ],
        },
      });
      final login = authority.token({
        ...base,
        'kind': 'operator_login',
        'sub': 'alice',
        'origin': 'https://pos.example',
        'credential': 'credential',
        'exp': seconds + 120,
      });
      final dispatched = <Map<String, dynamic>>[];
      final server = CompanionServer(
        verify: (_) async => throw StateError('Legacy path forbidden'),
        security: session,
        run: (operation, id, payload) async {
          dispatched.add({
            'operation': operation,
            'id': id,
            'payload': payload,
          });
          return {'outcome': 'succeeded'};
        },
      );
      final client = HttpClient(context: tls.clientContext);
      final verifier = OfflineGrantVerifier(
        keys: {},
        org: 'org',
        location: 'copou',
        companion: 'ecr',
      );
      try {
        await server.start(
          securityContext: tls.serverContext,
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        Future<(int, Map<String, dynamic>)> send(
          String path,
          Map<String, dynamic> body, {
          String origin = 'https://pos.example',
        }) async {
          final request = await client.postUrl(
            Uri.parse('https://127.0.0.1:${server.port}$path'),
          );
          request.headers.set('Origin', origin);
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
          final response = await request.close();
          return (
            response.statusCode,
            jsonDecode(await utf8.decoder.bind(response).join())
                as Map<String, dynamic>,
          );
        }

        for (final operation in operations) {
          final challenge = await send('/v2/challenge', {'lease': lease});
          expect(challenge.$1, 200);
          expect(
            verifier.verifySignature(
              companion.jwk,
              challenge.$2['message'],
              challenge.$2['signature'],
            ),
            isTrue,
          );
          final nonce = jsonDecode(challenge.$2['message'])['challenge'];
          final payload = jsonEncode({
            'operatorId': 'mallory',
            'posId': 'wrong-pos',
            'checkoutPolicy': {'card_mode': 'integrated'},
          });
          final message = jsonEncode({
            'challenge': nonce,
            'companion': 'ecr',
            'method': 'POST',
            'origin': 'https://pos.example',
            'commandId': 'sale-$operation',
            'operation': operation,
            'payloadHash': sha256.convert(utf8.encode(payload)).toString(),
          });
          final body = {
            'lease': lease,
            'operatorGrant': operator,
            'operatorLoginProof': login,
            'message': message,
            'signature': pos.signature(message),
            'payloadJson': payload,
          };
          final changed = await send('/v1/commands', {
            ...body,
            'payloadJson': '{}',
          });
          expect(changed.$1, 403);
          final wrongOrigin = await send(
            '/v1/commands',
            body,
            origin: 'https://evil.example',
          );
          expect(wrongOrigin.$1, 403);
          final wrongSignature = await send('/v1/commands', {
            ...body,
            'signature': authority.signature(message),
          });
          expect(wrongSignature.$1, 403);
          final result = await send('/v1/commands', body);
          expect(result.$1, 200);
          expect(
            verifier.verifySignature(
              companion.jwk,
              result.$2['resultJson'],
              result.$2['signature'],
            ),
            isTrue,
          );
          final signed = jsonDecode(result.$2['resultJson']) as Map;
          expect(signed['operatorId'], 'alice');
          expect(signed['posId'], 'pos');
          expect(signed['commandId'], 'sale-$operation');
          final forwarded = dispatched.last['payload'] as Map;
          expect(forwarded['operatorId'], 'alice');
          expect(forwarded['posId'], 'pos');
          if ([
            'saleAuthorize',
            'saleExternalPaymentConfirm',
          ].contains(operation)) {
            expect(forwarded['checkoutPolicy'], {'card_mode': 'external'});
          }
          expect((await send('/v1/commands', body)).$1, 403);
        }
        expect(dispatched.length, operations.length);
        for (final field in ['org', 'location', 'aud', 'companion']) {
          final foreign = authority.token({
            ...base,
            'kind': 'pair',
            'sub': 'pos',
            'peer': {'jwk': companion.jwk},
            field: 'foreign',
          });
          expect(
            (await send('/v2/challenge', {'lease': foreign})).$1,
            403,
            reason: field,
          );
        }
        await session.revokeLocally('pos');
        await session.restore();
        expect((await send('/v2/challenge', {'lease': lease})).$1, 403);
        expect(dispatched.length, operations.length);
      } finally {
        client.close(force: true);
        await server.close();
        await tls.directory.delete(recursive: true);
      }
    },
  );
}
