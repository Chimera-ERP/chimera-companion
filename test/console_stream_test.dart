import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/console/console_service.dart';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'signed_http_authorization_test.dart'
    show SigningFixture, NetworkTestBinding;
import 'console_test.dart' show AdapterFixture;
import 'tls_fixture.dart';

void main() {
  NetworkTestBinding();
  test(
    'real TLS console requires device proof, routes only current view and renews without losing USB ownership',
    () async {
      final tls = await TlsFixture.create(),
          authority = SigningFixture(71),
          peer = SigningFixture(72),
          device = SigningFixture(73);
      final adapter = AdapterFixture();
      final service = ConsoleService(adapter: adapter);
      await service.connect('synthetic');
      final security = OfflineSession(
        file: File('${tls.directory.path}/session'),
        org: 'org',
        location: 'lab',
        companion: 'peer',
        identity: peer,
      );
      await security.restore();
      await security.updateTrust({
        'signing_keys': [
          {...authority.jwk, 'kid': 'fixture-authority'},
        ],
        'peers': [],
      });
      final server = CompanionServer(
        console: service,
        security: security,
        verify: (_) async => throw StateError('No legacy grants'),
        run: (_, _, _) async =>
            throw StateError('No hardware business commands'),
      );
      await server.start(
        securityContext: tls.serverContext,
        address: InternetAddress.loopbackIPv4,
        port: 0,
        allowedHosts: {'localhost'},
      );
      final client = HttpClient(context: tls.clientContext);
      final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      String ticket(int offset) => authority.token({
        'iss': 'chimera-companion',
        'kind': 'kds-console',
        'org': 'org',
        'location': 'lab',
        'aud': 'peer',
        'companion': 'peer',
        'sub': 'station',
        'pos': 'station',
        'version': 1,
        'operations': ['console'],
        'cnf': {'jwk': device.jwk},
        'peer': {'jwk': peer.jwk},
        'origin': 'https://kds.example',
        'iat': seconds + offset,
        'nbf': seconds,
        'exp': seconds + offset + 60,
      });
      Future<Map<String, dynamic>> read(StreamIterator<dynamic> reader) async {
        expect(
          await reader.moveNext().timeout(const Duration(seconds: 4)),
          isTrue,
        );
        return Map<String, dynamic>.from(jsonDecode(reader.current as String));
      }

      Future<WebSocket> open() => WebSocket.connect(
        'wss://localhost:${server.port}/v1/kds-console',
        headers: {'Origin': 'https://kds.example'},
        customClient: client,
      );
      try {
        final bad = await open(), badReader = StreamIterator<dynamic>(bad);
        bad.add(jsonEncode({'ticket': ticket(0)}));
        final challenge = await read(badReader);
        bad.add(
          jsonEncode({
            'type': 'proof',
            'message': challenge['message'],
            'signature': peer.signature(challenge['message']),
          }),
        );
        expect(
          await badReader.moveNext().timeout(const Duration(seconds: 4)),
          isFalse,
        );
        expect(service.leased, isFalse);
        await bad.close();
        final socket = await open(), reader = StreamIterator<dynamic>(socket);
        socket.add(jsonEncode({'ticket': ticket(0)}));
        final good = await read(reader);
        socket.add(
          jsonEncode({
            'type': 'proof',
            'message': good['message'],
            'signature': device.signature(good['message']),
          }),
        );
        expect((await read(reader))['type'], 'ready');
        expect(service.leased, isTrue);
        socket.add(
          jsonEncode({
            'type': 'view',
            'version': 1,
            'revision': 1,
            'title': 'Lucrare',
            'keys': [
              {
                'id': 'pause',
                'label': 'Pauză',
                'icon': 'pause',
                'enabled': true,
              },
            ],
          }),
        );
        expect((await read(reader))['type'], 'shown');
        adapter.input.add(0);
        expect(await read(reader), {
          'type': 'press',
          'revision': 1,
          'id': 'pause',
          'sequence': 1,
        });
        socket.add(jsonEncode({'type': 'renew', 'ticket': ticket(1)}));
        expect((await read(reader))['type'], 'renewed');
        expect(service.leased, isTrue);
        await socket.close();
        await reader.cancel();
      } finally {
        await server.close();
        await service.close();
        await adapter.input.close();
        client.close(force: true);
        await tls.directory.delete(recursive: true);
      }
    },
  );
}
