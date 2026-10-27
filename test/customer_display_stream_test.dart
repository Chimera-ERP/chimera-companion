import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/customer_display.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'signed_http_authorization_test.dart'
    show SigningFixture, NetworkTestBinding;
import 'tls_fixture.dart';

void main() {
  NetworkTestBinding();
  late TlsFixture tls;
  late CompanionServer server;
  late OfflineSession session;
  final authority = SigningFixture(51),
      pos = SigningFixture(52),
      peer = SigningFixture(53);
  late String lease;
  late DateTime now;
  final calls = <Map<String, dynamic>>[];
  final clients = <HttpClient>[];
  final sockets = <WebSocket>[];
  Future<WebSocket> open({String origin = 'https://pos.example'}) async {
    final client = HttpClient(context: tls.clientContext);
    clients.add(client);
    final socket = await WebSocket.connect(
      'wss://localhost:${server.port}/v2/customer-display',
      headers: {'Origin': origin},
      customClient: client,
    );
    sockets.add(socket);
    return socket;
  }

  Future<Map<String, dynamic>> read(StreamIterator<dynamic> reader) async {
    expect(await reader.moveNext().timeout(const Duration(seconds: 3)), true);
    return jsonDecode(reader.current as String) as Map<String, dynamic>;
  }

  Map<String, dynamic> envelope(
    Map<String, dynamic> challenge, {
    String operation = 'customerDisplay',
    int revision = 1,
  }) {
    final payload = jsonEncode({
      'revision': revision,
      'currency': 'RON',
      'totalMinor': 650,
      'lines': [
        {'name': 'Apă', 'quantity': 1, 'totalMinor': 650},
      ],
      'posId': 'spoofed',
    });
    final message = jsonEncode({
      'companion': 'peer',
      'method': 'POST',
      'origin': 'https://pos.example',
      'commandId': 'cart-$revision',
      'operation': operation,
      'challenge': jsonDecode(challenge['message'])['challenge'],
      'payloadHash': sha256.convert(utf8.encode(payload)).toString(),
    });
    return {
      'type': 'snapshot',
      'lease': lease,
      'message': message,
      'signature': pos.signature(message),
      'payloadJson': payload,
    };
  }

  setUp(() async {
    tls = await TlsFixture.create();
    now = DateTime.now();
    calls.clear();
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    session = OfflineSession(
      file: File('${tls.directory.path}/trust'),
      org: 'org',
      location: 'location',
      companion: 'peer',
      identity: peer,
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
    lease = authority.token({
      'iss': 'chimera-companion',
      'kind': 'pair',
      'org': 'org',
      'location': 'location',
      'aud': 'peer',
      'companion': 'peer',
      'sub': 'pos',
      'pos': 'pos',
      'version': 1,
      'iat': seconds,
      'nbf': seconds,
      'exp': seconds + 300,
      'operations': ['customerDisplay', 'fiscalReceipt'],
      'cnf': {'jwk': pos.jwk},
      'peer': {'jwk': peer.jwk},
    });
    server = CompanionServer(
      verify: (_) async => throw StateError('legacy forbidden'),
      run: (_, _, _) async => throw StateError('unverified dispatch forbidden'),
      security: session,
      runAuthorized: (op, id, payload, expires) async {
        expect(op, 'customerDisplay');
        customerDisplayPayload(payload);
        calls.add(payload);
        return {
          'outcome': 'succeeded',
          'customerDisplay': {'applied': true, 'state': 'showing'},
        };
      },
    );
    await server.start(
      securityContext: tls.serverContext,
      address: InternetAddress.loopbackIPv4,
      port: 0,
    );
  });
  tearDown(() async {
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    for (final client in clients) {
      client.close(force: true);
    }
    clients.clear();
    await server.close();
    await tls.directory.delete(recursive: true);
  });
  test(
    'signed persistent snapshots use normal auth and inject the verified POS, without ECR',
    () async {
      final socket = await open(),
          reader = StreamIterator<dynamic>(sockets.last);
      socket.add(jsonEncode({'type': 'hello', 'lease': lease}));
      var reply = await read(reader);
      expect(reply['type'], 'ready');
      expect(calls, isEmpty);
      for (var revision = 1; revision <= 3; revision++) {
        final request = envelope(
          Map<String, dynamic>.from(reply['challenge']),
          revision: revision,
        );
        socket.add(jsonEncode(request));
        reply = await read(reader);
        expect(reply['type'], 'ack');
        expect(reply['result']['signature'], isNotEmpty);
        final result = jsonDecode(reply['result']['resultJson']);
        expect(result['commandId'], 'cart-$revision');
        expect(result['posId'], 'pos');
        expect(
          result['payloadHash'],
          jsonDecode(request['message'])['payloadHash'],
        );
      }
      expect(calls.map((e) => e['revision']), [1, 2, 3]);
      expect(calls.every((e) => e['posId'] == 'pos'), true);
      await reader.cancel();
    },
  );
  for (final invalid in [
    'copied-token',
    'changed-payload',
    'replay',
    'fiscal',
    'revoked',
    'expired',
  ]) {
    test('rejects $invalid on an already open display socket', () async {
      final socket = await open(),
          reader = StreamIterator<dynamic>(sockets.last);
      socket.add(jsonEncode({'type': 'hello', 'lease': lease}));
      final ready = await read(reader);
      final request = envelope(
        Map<String, dynamic>.from(ready['challenge']),
        operation: invalid == 'fiscal' ? 'fiscalReceipt' : 'customerDisplay',
      );
      if (invalid == 'copied-token') {
        request['signature'] = peer.signature(request['message']);
      }
      if (invalid == 'changed-payload') request['payloadJson'] = '{}';
      if (invalid == 'replay') {
        socket.add(jsonEncode(request));
        await read(reader);
      }
      if (invalid == 'revoked') await session.revokeLocally('pos');
      if (invalid == 'expired') now = now.add(const Duration(minutes: 6));
      socket.add(jsonEncode(request));
      expect(
        await reader.moveNext().timeout(const Duration(seconds: 3)),
        false,
      );
      expect(calls.length, invalid == 'replay' ? 1 : 0);
      expect(socket.closeCode, WebSocketStatus.policyViolation);
    });
  }
  test('rejects insecure origins and oversized frames', () async {
    await expectLater(
      open(origin: 'http://pos.example'),
      throwsA(isA<WebSocketException>()),
    );
    final socket = await open(), reader = StreamIterator<dynamic>(sockets.last);
    socket.add('a' * 32769);
    expect(await reader.moveNext().timeout(const Duration(seconds: 3)), false);
    expect(socket.closeCode, WebSocketStatus.messageTooBig);
    expect(calls, isEmpty);
  });
}
