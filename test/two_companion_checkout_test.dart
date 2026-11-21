import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:chimera_companion/local_bridge.dart';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/datecs_device_client.dart';
import 'package:chimera_companion/hardware/datecs_gateway_protocol.dart';
import 'datecs_device_client_test.dart' as datecs;
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
    FlutterSecureStorage.setMockInitialValues({'local_hardware_v1':jsonEncode({'host':'192.168.1.20','vivaEnabled':'false'})});
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
  for (final (model, profile, outcome, transport) in [
    (FiscalModel.tremolM20, DatecsProfile.auto, CommandOutcome.succeeded, 'lan'),
    (FiscalModel.tremolFp21, DatecsProfile.auto, CommandOutcome.succeeded, 'lan'),
    (FiscalModel.datecsDp25, DatecsProfile.asciiMx, CommandOutcome.succeeded, 'lan'),
    (FiscalModel.datecsDp25, DatecsProfile.legacyRou, CommandOutcome.succeeded, 'lan'),
    (FiscalModel.tremolM20, DatecsProfile.auto, CommandOutcome.rejected, 'lan'),
    (FiscalModel.tremolM20, DatecsProfile.auto, CommandOutcome.unknown, 'lan'),
    (FiscalModel.tremolFp21, DatecsProfile.auto, CommandOutcome.succeeded, 'usb'),
    (FiscalModel.tremolFp21, DatecsProfile.auto, CommandOutcome.succeeded, 'bluetooth'),
  ]) {
    test(
      'signed checkout with ${model.name}/${profile.name} on $transport preserves ${outcome.name} across restart',
      () async {
        final tls = await TlsFixture.create();
        final authority = SigningFixture(27),
            pos = SigningFixture(28),
            ecrKey = SigningFixture(29),
            terminalKey = SigningFixture(30);
        final terminal = PaymentFixture(outcome);
        final datecsServer = profile == DatecsProfile.asciiMx
            ? await ServerSocket.bind(InternetAddress.loopbackIPv4, 0)
            : null;
        addTearDown(() => datecsServer?.close());
        final wire = datecs.Peer();
        datecsServer?.listen((socket) {
          final buffer = <int>[];
          socket.listen((chunk) async {
            buffer.addAll(chunk);
            final length = DatecsGatewayProtocol.frameLength(buffer);
            if (length == null || buffer.length < length) return;
            final request = buffer.sublist(0, length);
            buffer.removeRange(0, length);
            socket.add(
              await wire.exchange(request, DatecsGatewayProtocol.frameLength),
            );
          }, onDone: socket.destroy);
        });
        final legacy = profile == DatecsProfile.legacyRou;
        if (legacy) {
          const channel = MethodChannel('chimera/hardware/datecs_rou');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'readVatRates');
            return {
              'enabled': '1100',
              'decimals': '2',
              'rates': ['21.00', '11.00', '0.00', '0.00'],
            };
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        }
        final endpoint = switch (transport) {
          'usb' => FiscalSerialEndpoint(transport: 'usb', deviceId: 'a' * 64, model: model),
          'bluetooth' => FiscalSerialEndpoint(transport: 'bluetooth', deviceId: 'AA:BB:CC:DD:EE:01', model: model),
          _ => LanEndpoint(host:'127.0.0.1',port: datecsServer?.port ?? 9100),
        };
        final (address, port) = switch (endpoint) {
          LanEndpoint(:final host, :final port) => (host, port),
          FiscalSerialEndpoint() => (endpoint.key, 0),
        };
        final ecr = BridgeFiscalFixture(
          profile: profile,
          connection: FiscalConnection(
            id: 'ecr',
            model: model,
            endpoint: endpoint,
            operatorNumber: 1,
            operatorPassword: '1234',
            cashPaymentCode: legacy ? 'P' : '0',
            cardPaymentCode: legacy ? 'D' : '1',
          ),
        );
        FlutterSecureStorage.setMockInitialValues({
          'local_hardware_v1': jsonEncode({
            'transport': transport,
            if (endpoint is FiscalSerialEndpoint) 'deviceId': endpoint.deviceId,
            if (endpoint is LanEndpoint) ...{'host': address, 'port': port.toString()},
            'vivaEnabled': 'true',
            'vivaHost': '127.0.0.1',
            'vivaPort': '9564',
          }),
        });
        final equipment = [
          {
            'kind': 'ecr',
            'companion_id': 'ecr',
            'host': address,
            'port': port,
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
          for (final method in ['cash', 'card']) {
            final invalidId = 'bad-vat-$method';
            final unsupported = {
              ...facts,
              'paymentMethod': method,
              'lines': [
                {...(facts['lines'] as List).single as Map, 'vatRate': 77},
              ],
            };
            final refused = await fiscal.command('saleAuthorize', invalidId, {
              'saleId': invalidId,
              'receiptJson': jsonEncode(unsupported),
              'receiptPreflightVersion': 1,
              'lifecycleVersion': 1,
            });
            expect(refused.$1, 200);
            expect(jsonDecode(refused.$2['resultJson'])['outcome'], 'rejected');
            if (method == 'card') {
              final denied = await bank.command('payment', paymentId, {
                'saleId': invalidId,
                'amountMinor': 500,
                'currency': 'RON',
                'receiptCommandId': invalidId,
                'receiptCompanionId': 'ecr',
                'saleAuthorization': refused.$2,
              });
              expect(denied.$1, 403);
            }
            expect(terminal.calls, 0);
            expect(ecr.prints, 0);
          }
          if (datecsServer != null) expect(wire.requests, isNotEmpty);
          final admission = await fiscal.command('saleAuthorize', 'sale', {
            'saleId': 'sale',
            'receiptJson': jsonEncode(facts),
            'lifecycleVersion': 1,
            'receiptPreflightVersion': 1,
          });
          expect(admission.$1, 200);
          if (transport != 'lan') {
            final previousKey = 'sale_admission_${CommandJournal.fingerprint('old-route','saleAuthorize',{'id':'original-sale'})}';
            await const FlutterSecureStorage().write(key:previousKey,value:jsonEncode({
              'saleId':'original-sale','equipmentId':'old-route','phase':'payment_started',
            }));
            await fiscal.restartBridge();
            final prior = await fiscal.command('saleAuthorize','original-sale',{
              'saleId':'original-sale','receiptJson':jsonEncode(facts),'lifecycleVersion':1,'receiptPreflightVersion':1,
            });
            expect(jsonDecode(prior.$2['resultJson'])['outcome'],'rejected');
            expect(terminal.calls,0);
            expect(ecr.prints,0);
            final foreign = await fiscal.bridge.run('zReport','foreign-write',{'confirmCloseDay': true},
                expectedEndpoint: '192.168.1.20:9100');
            expect(foreign['outcome'],'rejected');
          }
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
          // A pre-upgrade ECR could sign a legitimate admission without ever
          // checking its register. Such proof is only usable for journal lookup.
          final legacyResult = jsonDecode(admission.$2['resultJson']);
          (legacyResult['saleAdmission'] as Map)
            ..remove('receiptPreflightVersion')
            ..remove('receiptConfigurationHash');
          final legacyJson = jsonEncode(legacyResult);
          final legacyPayload = {
            ...paymentPayload,
            'saleAuthorization': {
              'resultJson': legacyJson,
              'signature': ecrKey.signature(legacyJson),
            },
          };
          final missing = await bank.command('payment', paymentId, {
            ...legacyPayload,
            'recoveryOnly': true,
          });
          expect(jsonDecode(missing.$2['resultJson'])['outcome'], 'unknown');
          expect(
            (await bank.command('payment', paymentId, legacyPayload)).$1,
            403,
          );
          expect(terminal.calls, 0);
          if (datecsServer != null) {
            final originalVat = wire.vatResponse;
            wire.vatResponse = originalVat.replaceFirst(
              '21.00\t11.00',
              '11.00\t21.00',
            );
            final changed = await fiscal
                .command('salePaymentStart', paymentId, {
                  'saleId': 'sale',
                  'amountMinor': 500,
                  'currency': 'RON',
                  'paymentCompanion': 'terminal',
                  'receiptJson': jsonEncode(facts),
                });
            expect(
              changed.$1,
              403,
              reason: 'The same rate now belongs to another physical VAT group',
            );
            expect(terminal.calls, 0);
            expect(ecr.prints, 0);
            wire.vatResponse = originalVat;
          }
          final started = await fiscal.command('salePaymentStart', paymentId, {
            'saleId': 'sale',
            'amountMinor': 500,
            'currency': 'RON',
            'paymentCompanion': 'terminal',
            'receiptJson': jsonEncode(facts),
          });
          expect(started.$1, 200);
          paymentPayload['paymentAuthorization'] = started.$2;
          if (transport != 'lan') {
            final old = jsonDecode(started.$2['resultJson']);
            old['paymentAdmission']['equipmentId'] = 'tremolFp21:192.168.1.20:9100';
            final oldJson = jsonEncode(old);
            final stale = await bank.command('payment', paymentId, {
              ...paymentPayload,
              'paymentAuthorization': {'resultJson': oldJson, 'signature': await ecrKey.sign(oldJson)},
            });
            expect(stale.$1, 403);
            expect(terminal.calls, 0);
          }
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
            final legacyRecovery = await bank.command('payment', paymentId, {
              ...legacyPayload,
              'recoveryOnly': true,
            });
            expect(
              jsonDecode(legacyRecovery.$2['resultJson'])['reference'],
              'synthetic-bank-reference',
            );
            expect(terminal.calls, 1);
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
            ecr.offline = false;
            final cashFacts = {...facts, 'paymentMethod': 'cash'};
            final cash = await fiscal.command('saleAuthorize', 'cash-sale', {
              'saleId': 'cash-sale',
              'receiptJson': jsonEncode(cashFacts),
              'receiptPreflightVersion': 1,
              'lifecycleVersion': 1,
            });
            expect(jsonDecode(cash.$2['resultJson'])['outcome'], 'succeeded');
            final cashReceipt = await fiscal.command(
              'fiscalReceipt',
              'cash-sale',
              {
                ...cashFacts,
                'saleId': 'cash-sale',
                'saleAuthorization': cash.$2,
              },
            );
            expect(
              jsonDecode(cashReceipt.$2['resultJson'])['outcome'],
              'succeeded',
            );
            expect(ecr.prints, 2);
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
