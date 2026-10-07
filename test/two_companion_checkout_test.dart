import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/local_bridge.dart';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'signed_http_authorization_test.dart'
    show SigningFixture, NetworkTestBinding, BridgeFiscalFixture;
import 'tls_fixture.dart';

class PaymentFixture implements PaymentTerminalAdapter {
  PaymentFixture(this.outcome);
  final CommandOutcome outcome;
  int calls = 0;
  @override
  String get vendor => 'synthetic-terminal';
  @override
  Future<HardwareResult> pay(PaymentRequest request) async {
    calls++;
    return HardwareResult(
      outcome,
      reference: 'synthetic-bank-reference',
      message: 'Fixture terminal outcome',
    );
  }

  @override
  Future<HardwareResult> reconcile(PaymentRequest request) async =>
      throw StateError('Unexpected terminal reconciliation');
}

/// Two actual TLS servers/session verifiers/bridges/journals. Only device
/// keystore storage and the physical bank/ECR adapters are substituted.
class CheckoutPeer {
  CheckoutPeer({
    required this.id,
    required this.identity,
    required this.authority,
    required this.pos,
    required this.tls,
    required this.ecr,
    required this.terminal,
  });
  final String id;
  final SigningFixture identity, authority, pos;
  final TlsFixture tls;
  final BridgeFiscalFixture ecr;
  final PaymentFixture terminal;
  late OfflineSession security;
  late LocalBridge bridge;
  late CompanionServer server;
  late HttpClient client;
  late String lease, operator, login;
  late File journal;
  LocalBridge makeBridge() =>
      LocalBridge(
          journal: CommandJournal(journal),
          security: security,
          deviceFactory: (_) => ecr,
          paymentFactory: (_) => terminal,
        )
        ..companionId = id
        ..locationId = 'copou';
  Future<void> start(List<Map<String, dynamic>> equipment) async {
    journal = File('${tls.directory.path}/$id-journal');
    security = OfflineSession(
      file: File('${tls.directory.path}/$id-trust'),
      org: 'org',
      location: 'copou',
      companion: id,
      identity: identity,
    );
    await security.restore();
    await security.updateTrust({
      'signing_keys': [
        {...authority.jwk, 'kid': 'fixture-authority'},
      ],
      'peers': [
        {'pos_id': 'pos', 'version': 1, 'revoked': false},
      ],
      'equipment': equipment,
    });
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final base = {
      'iss': 'chimera-companion',
      'org': 'org',
      'location': 'copou',
      'aud': id,
      'companion': id,
      'pos': 'pos',
      'version': 1,
      'iat': seconds,
      'nbf': seconds,
      'exp': seconds + 600,
      'operations': [
        'saleAuthorize',
        'salePaymentStart',
        'salePaymentReject',
        'saleAbandon',
        'fiscalReceipt',
        'payment',
      ],
      'cnf': {'jwk': pos.jwk},
    };
    lease = authority.token({
      ...base,
      'kind': 'pair',
      'sub': 'pos',
      'peer': {'jwk': identity.jwk},
    });
    operator = authority.token({
      ...base,
      'kind': 'operator',
      'sub': 'alice',
      'operatorName': 'Alice',
      'checkoutPolicy': {'card_mode': 'integrated'},
      'webauthn': {
        'origin': 'https://pos.example',
        'credentials': [
          {'id': 'credential', 'counter': 0},
        ],
      },
    });
    login = authority.token({
      ...base,
      'kind': 'operator_login',
      'sub': 'alice',
      'origin': 'https://pos.example',
      'credential': 'credential',
      'exp': seconds + 120,
    });
    bridge = makeBridge();
    server = CompanionServer(
      verify: (_) async => throw StateError('Legacy auth forbidden'),
      security: security,
      run: (operation, id, payload) => bridge.run(operation, id, payload),
    );
    await server.start(
      securityContext: tls.serverContext,
      address: InternetAddress.loopbackIPv4,
      port: 0,
    );
    client = HttpClient(context: tls.clientContext);
  }

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
    final encoded = jsonEncode(payload);
    final message = jsonEncode({
      'challenge': jsonDecode(challenge.$2['message'])['challenge'],
      'companion': this.id,
      'method': 'POST',
      'origin': 'https://pos.example',
      'operation': operation,
      'commandId': id,
      'payloadHash': sha256.convert(utf8.encode(encoded)).toString(),
    });
    return send('/v1/commands', {
      'lease': lease,
      'operatorGrant': operator,
      'operatorLoginProof': login,
      'message': message,
      'signature': pos.signature(message),
      'payloadJson': encoded,
    });
  }

  Future<void> restartBridge() async {
    await bridge.close();
    bridge = makeBridge();
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close();
    await bridge.close();
  }
}

void main() {
  NetworkTestBinding();
  test('signed cash abandonment releases only rejected receipts, including after restart',() async {
    final tls=await TlsFixture.create();
    FlutterSecureStorage.setMockInitialValues({'local_hardware_v1':jsonEncode({'vivaEnabled':'false'})});
    final identity=SigningFixture(29);
    final fiscal=CheckoutPeer(id:'ecr',identity:identity,authority:SigningFixture(27),pos:SigningFixture(28),tls:tls,
      ecr:BridgeFiscalFixture(),terminal:PaymentFixture(CommandOutcome.succeeded));
    await fiscal.start([{'kind':'ecr','companion_id':'ecr','host':'192.168.1.20','port':9100,'public_jwk':identity.jwk}]);
    try {
      for(final outcome in CommandOutcome.values) {
        final sale='cash-${outcome.name}';
        final admitted=await fiscal.command('saleAuthorize',sale,{'saleId':sale,'lifecycleVersion':1,
          'receiptJson':jsonEncode({'currency':'RON','paymentMethod':'cash','totalMinor':500,'lines':[
            {'name':'Coffee','quantity':'1','unitPriceMinor':500,'grossTotalMinor':500,'vatRate':21}]})});
        expect(admitted.$1,200);
        await CommandJournal(fiscal.journal).execute(id:sale,deviceId:fiscal.ecr.id,operation:'fiscalReceipt',payload:{},
          dispatch:() async=>HardwareResult(outcome,message:'Fixture fiscal result'));
        await fiscal.restartBridge();
        final cancelled=await fiscal.command('saleAbandon','$sale-abandon',{'saleId':sale});
        expect(cancelled.$1,200);
        expect(jsonDecode(cancelled.$2['resultJson'])['outcome'],outcome==CommandOutcome.rejected?'succeeded':'rejected');
        if(outcome==CommandOutcome.rejected) {
          expect(jsonDecode(cancelled.$2['resultJson'])['saleAdmission']['phase'],'abandoned');
          final replay=await fiscal.command('saleAbandon','$sale-abandon',{'saleId':sale});
          expect(jsonDecode(replay.$2['resultJson'])['outcome'],'succeeded');
        }
      }
    } finally {await fiscal.close();await tls.directory.delete(recursive:true);}
  });
  for (final outcome in [
    CommandOutcome.succeeded,
    CommandOutcome.rejected,
    CommandOutcome.unknown,
  ]) {
    test(
      'two signed Companion peers preserve ${outcome.name} bank result across restart',
      () async {
        final tls = await TlsFixture.create();
        FlutterSecureStorage.setMockInitialValues({
          'local_hardware_v1': jsonEncode({
            'vivaEnabled': 'true',
            'vivaHost': '127.0.0.1',
            'vivaPort': '9564',
          }),
        });
        final authority = SigningFixture(27),
            pos = SigningFixture(28),
            ecrKey = SigningFixture(29),
            terminalKey = SigningFixture(30);
        final ecr = BridgeFiscalFixture(), terminal = PaymentFixture(outcome);
        final equipment = [
          {
            'kind': 'ecr',
            'companion_id': 'ecr',
            'host': '192.168.1.20',
            'port': 9100,
            'public_jwk': ecrKey.jwk,
          },
          {
            'kind': 'payment',
            'companion_id': 'terminal',
            'host': '127.0.0.1',
            'port': 9564,
            'public_jwk': terminalKey.jwk,
          },
        ];
        final fiscal = CheckoutPeer(
          id: 'ecr',
          identity: ecrKey,
          authority: authority,
          pos: pos,
          tls: tls,
          ecr: ecr,
          terminal: terminal,
        );
        final bank = CheckoutPeer(
          id: 'terminal',
          identity: terminalKey,
          authority: authority,
          pos: pos,
          tls: tls,
          ecr: ecr,
          terminal: terminal,
        );
        await fiscal.start(equipment);
        await bank.start(equipment);
        try {
          const paymentId = '12345678-1234-4234-8234-123456789012';
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
          final admission = await fiscal.command('saleAuthorize', 'sale', {
            'saleId': 'sale',
            'receiptJson': jsonEncode(facts),
            'lifecycleVersion': 1,
          });
          expect(admission.$1, 200);
          final paymentPayload = <String, dynamic>{
            'saleId': 'sale',
            'amountMinor': 500,
            'currency': 'RON',
            'receiptCommandId': 'sale',
            'receiptCompanionId': 'ecr',
            'saleAuthorization': admission.$2,
          };
          expect(
            (await bank.command('payment', paymentId, paymentPayload)).$1,
            403,
          );
          expect(terminal.calls, 0);
          final started = await fiscal.command('salePaymentStart', paymentId, {
            'saleId': 'sale',
            'amountMinor': 500,
            'currency': 'RON',
            'paymentCompanion': 'terminal',
          });
          expect(started.$1, 200);
          paymentPayload['paymentAuthorization'] = started.$2;
          final paid = await bank.command('payment', paymentId, paymentPayload);
          expect(paid.$1, 200);
          final paymentResult = jsonDecode(paid.$2['resultJson']) as Map;
          expect(paymentResult['outcome'], outcome.name);
          expect(terminal.calls, 1);
          await bank.restartBridge();
          final recovered = await bank.command(
            'payment',
            paymentId,
            paymentPayload,
          );
          expect(recovered.$1, 200);
          expect(
            jsonDecode(recovered.$2['resultJson'])['outcome'],
            outcome.name,
          );
          expect(terminal.calls, 1);
          expect(
            (await bank.command(
              'payment',
              'different-payment-id',
              paymentPayload,
            )).$1,
            403,
          );
          expect(
            (await bank.command('payment', paymentId, {
              ...paymentPayload,
              'amountMinor': 501,
            })).$1,
            409,
          );
          expect(terminal.calls, 1);
          if (outcome == CommandOutcome.succeeded) {
            expect(
              (await fiscal.command('salePaymentReject', 'release-paid', {
                'saleId': 'sale',
                'paymentRejectionProof': paid.$2,
              })).$1,
              403,
            );
            final receipt = {
              ...facts,
              'saleId': 'sale',
              'saleAuthorization': admission.$2,
              'paymentCommandId': paymentId,
              'paymentEvidence': paymentResult['paymentEvidence'],
              'paymentSignature': paymentResult['paymentSignature'],
            };
            final altered = {
              ...receipt,
              'paymentEvidence': (paymentResult['paymentEvidence'] as String)
                  .replaceFirst('500', '501'),
            };
            expect(
              (await fiscal.command('fiscalReceipt', 'sale', altered)).$1,
              403,
            );
            expect(ecr.prints, 0);
            final printed = await fiscal.command(
              'fiscalReceipt',
              'sale',
              receipt,
            );
            expect(printed.$1, 200);
            expect(
              jsonDecode(printed.$2['resultJson'])['outcome'],
              'succeeded',
            );
            expect(ecr.prints, 1);
            await fiscal.restartBridge();
            ecr.offline = true;
            final repeat = await fiscal.command(
              'fiscalReceipt',
              'sale',
              receipt,
            );
            expect(repeat.$1, 200);
            expect(jsonDecode(repeat.$2['resultJson'])['outcome'], 'succeeded');
            expect(ecr.prints, 1);
            expect(terminal.calls, 1);
          } else {
            final released = await fiscal.command(
              'salePaymentReject',
              'release',
              {'saleId': 'sale', 'paymentRejectionProof': paid.$2},
            );
            expect(released.$1, outcome == CommandOutcome.rejected ? 200 : 403);
            expect(ecr.prints, 0);
            if (outcome == CommandOutcome.rejected) {
              expect(
                jsonDecode(released.$2['resultJson'])['saleAdmission']['phase'],
                'abandoned',
              );
              await fiscal.restartBridge();
              final retry = await fiscal.command(
                'salePaymentReject',
                'release',
                {'saleId': 'sale', 'paymentRejectionProof': paid.$2},
              );
              expect(retry.$1, 200);
              expect(
                jsonDecode(retry.$2['resultJson'])['saleAdmission']['phase'],
                'abandoned',
              );
            }
          }
        } finally {
          await fiscal.close();
          await bank.close();
          await tls.directory.delete(recursive: true);
        }
      },
    );
  }
}
