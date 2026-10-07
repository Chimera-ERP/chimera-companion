import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'package:chimera_companion/security/device_identity.dart';
import 'tls_fixture.dart';

// Authorization is stubbed in this transport contract test. Cryptographic
// verification has separate ES256 tests; no hardware/payment is dispatched.
class FixtureIdentity extends DeviceIdentity {
  @override
  Future<String> sign(String message) async=>'fixture-signature';
}
class VerifiedClaimsSession extends OfflineSession {
  VerifiedClaimsSession(File file):super(file:file,org:'org',location:'copou',companion:'ecr',identity:FixtureIdentity());
  late Map<String,dynamic> claims;
  bool denied=false;
  @override
  Future<Map<String,dynamic>> authorize(Map<String,dynamic> body,String origin) async {
    if(denied)throw const FormatException('Rejected fixture authorization');
    return claims;
  }
}

void main() {
  late TlsFixture tls;
  setUpAll(() async => tls = await TlsFixture.create());
  tearDownAll(() async => tls.directory.delete(recursive: true));
  test('HTTPS dispatch takes operator and external-card policy only from verified claims',() async {
    final session=VerifiedClaimsSession(File('${tls.directory.path}/transport-test-trust'));
    final received=<Map<String,dynamic>>[];
    final refusals=<String>[],failures=<String>[];
    final server=CompanionServer(verify:(_)async=>{},security:session,
      onAuthorizationError:(reason) async {refusals.add(reason);},
      onFailure:(code,detail) async {failures.add('$code: $detail');},
      run:(_,_,_)async=>throw StateError('Authorized handler required'),
      runAuthorized:(operation,id,payload,expiry) async {
        received.add({'operation':operation,'id':id,'payload':payload,'expiry':expiry});
        return {'outcome':'succeeded','operatorId':'forged-result','posId':'forged-result'};
      });
    await server.start(securityContext:tls.serverContext,address:InternetAddress.loopbackIPv4,port:0);
    final client=HttpClient(context:tls.clientContext);
    Future<HttpClientResponse> send() async {
      final request=await client.postUrl(Uri.parse('https://127.0.0.1:${server.port}/v1/commands'));
      request.headers.set('Origin','https://pos.example');request.headers.contentType=ContentType.json;
      request.write(jsonEncode({'lease':'fixture-lease'}));
      return request.close();
    }
    try {
      for(final operation in ['saleExternalPaymentConfirm','salePaymentStart','salePaymentReject']) {
        session.claims={'operation':operation,'commandId':'same-sale-$operation','operatorId':'alice','operatorName':'Alice','pos':'pos',
          'canResetOperatorReport':false,'authorizationExpires':123456,'payloadHash':'original-hash',
          'checkoutPolicy':{'card_mode':'external'},'payload':{'operatorId':'mallory','posId':'foreign-pos','operatorName':'Forged','checkoutPolicy':{'card_mode':'integrated'}}};
        final response=await send();expect(response.statusCode,200);
        final body=jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        final signed=jsonDecode(body['resultJson'] as String) as Map;
        expect(signed['operatorId'],'alice');expect(signed['posId'],'pos');expect(signed['companion'],'ecr');
        expect(signed['operation'],operation);expect(signed['payloadHash'],'original-hash');
        final payload=received.last['payload'] as Map;
        expect(payload['operatorId'],'alice');expect(payload['posId'],'pos');expect(payload['operatorName'],'Alice');
        if(operation=='saleExternalPaymentConfirm')expect(payload['checkoutPolicy'],{'card_mode':'external'});
      }
      session.denied=true;
      final denied=await send();expect(denied.statusCode,403);await denied.drain<void>();
      expect(received.length,3);
      expect(refusals,['Rejected fixture authorization']);
      expect(failures.single,contains('HTTP 403'));
    } finally {client.close(force:true);await server.close();}
  });
  test('rejects rebinding hostname before health or hardware access', () async {
    final server = CompanionServer(
      verify: (_) async => {},
      run: (_, _, _) async => {},
    );
    await server.start(
      securityContext: tls.serverContext,
      address: InternetAddress.loopbackIPv4,
      port: 0,
      allowedHosts: {'companion.example.test'},
    );
    final client = HttpClient(context: tls.clientContext);
    try {
      final request = await client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/health'),
      );
      request.headers.set('Host', 'evil.example.test');
      final response = await request.close();
      expect(response.statusCode, 421);
      await response.drain<void>();
      final valid = await client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/health'),
      );
      valid.headers.set('Host', 'companion.example.test');
      final accepted = await valid.close();
      expect(accepted.statusCode, 200);
      await accepted.drain<void>();
    } finally {
      client.close(force: true);
      await server.close();
    }
  });
  test(
    'requires payload-bound, origin-bound, unexpired authorization',
    () async {
      var dispatched = 0;
      final payload = jsonEncode({
        'lines': ['TEST'],
      });
      final claims = <String, dynamic>{
        'origin': 'https://pos.example',
        'hash': sha256.convert(utf8.encode(payload)).toString(),
        'exp': DateTime.now().millisecondsSinceEpoch + 60000,
        'operation': 'nonFiscal',
        'commandId': 'stable-command',
      };
      final server = CompanionServer(
        verify: (_) async => claims,
        run: (_, id, payload) async {
          dispatched++;
          return {'outcome': 'succeeded'};
        },
      );
      await server.start(
        securityContext: tls.serverContext,
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      final client = HttpClient(context: tls.clientContext);
      Future<int> send({
        String? origin = 'https://pos.example',
        String? data,
      }) async {
        final request = await client.postUrl(
          Uri.parse('https://127.0.0.1:${server.port}/v1/commands'),
        );
        if (origin != null) request.headers.set('Origin', origin);
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'ticket': 'verified-ticket',
            'payloadJson': data ?? payload,
          }),
        );
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      try {
        expect(await send(origin: null), 403);
        expect(await send(origin: 'https://other.example'), 403);
        expect(await send(data: '{}'), 403);
        expect(dispatched, 0);
        expect(await send(), 200);
        expect(dispatched, 1);
        claims['operation'] = 'paymentTest';
        expect(await send(origin: 'https://other.example'), 403);
        expect(await send(), 200);
        expect(dispatched, 2);
        claims['operation'] = 'unauthorizedWrite';
        expect(await send(), 403);
        claims['exp'] = 0;
        expect(await send(), 403);
        expect(dispatched, 2);
      } finally {
        client.close(force: true);
        await server.close();
      }
    },
  );
}
