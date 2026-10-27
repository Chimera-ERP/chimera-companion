import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/local_bridge.dart';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/erp_commands.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'package:chimera_companion/security/offline_grant.dart';
import 'signed_http_authorization_test.dart'
    show SigningFixture, NetworkTestBinding;
import 'tls_fixture.dart';

void main() {
  NetworkTestBinding();
  test(
    'signed offline output measurements are provisional, scoped, durable and never auto reprinted',
    () async {
      final tls = await TlsFixture.create();
      final authority = SigningFixture(71),
          companion = SigningFixture(72),
          kds = SigningFixture(73),
          foreign = SigningFixture(74);
      var now = DateTime.now().toUtc();
      final seconds = now.millisecondsSinceEpoch ~/ 1000;
      const leaseId = '00000000-0000-4000-8000-000000000001';
      const reportId = '00000000-0000-4000-8000-000000000002';
      const commandId = '00000000-0000-4000-8000-000000000003';
      final scope = <String, dynamic>{
        'version': 1,
        'lease_id': leaseId,
        'operation_id': 'operation',
        'product_id': 'product',
        'product': 'Croissant cu ciocolată',
        'unit': 'kg',
        'printer_id': 'printer:192.168.1.30:9100',
        'device_id': 'kds',
        'companion_id': 'companion',
        'origin': 'https://kds.example',
        'max_quantity_decimal': '10',
        'max_commands': 2,
        'not_before': now.subtract(const Duration(hours: 1)).toIso8601String(),
        'expires_at': DateTime.fromMillisecondsSinceEpoch(
          (seconds + 172800) * 1000,
          isUtc: true,
        ).toIso8601String(),
      };
      final grant = <String, dynamic>{
        'iss': 'chimera-companion',
        'kind': 'production-label-lease',
        'org': 'org',
        'location': 'location',
        'aud': 'companion',
        'companion': 'companion',
        'sub': 'operator',
        'pos': 'kds',
        'version': 1,
        'operations': ['productionLabel'],
        'session_id': leaseId,
        'credential': 'credential',
        'auth_at': seconds,
        'origin': scope['origin'],
        'commandId': 'operation',
        'printerId': scope['printer_id'],
        'provisional': true,
        'labelScope': scope,
        'payloadHash': hardwarePayloadHash(scope),
        'cnf': {'jwk': kds.jwk},
        'peer': {'jwk': companion.jwk},
        'iat': seconds,
        'nbf': seconds,
        'exp': seconds + 172800,
      };
      final token = authority.token(grant);
      final session = OfflineSession(
        file: File('${tls.directory.path}/trust'),
        org: 'org',
        location: 'location',
        companion: 'companion',
        identity: companion,
        now: () => now,
      );
      await session.restore();
      await session.updateTrust({
        'signing_keys': [
          {...authority.jwk, 'kid': 'fixture-authority'},
        ],
        'peers': [],
        'equipment': [
          {
            'kind': 'printer',
            'companion_id': 'companion',
            'host': '192.168.1.30',
            'port': 9100,
          },
        ],
      });
      FlutterSecureStorage.setMockInitialValues({
        'production_printer_v1': jsonEncode({
          'name': 'Labels',
          'protocol': 'zpl',
          'host': '192.168.1.30',
          'port': 9100,
          'widthDots': 576,
          'heightDots': 1600,
        }),
      });
      final payload = <String, dynamic>{
        'version': 3,
        'factKind': 'offline_output',
        'commandId': commandId,
        'operation': 'productionLabel',
        'printerId': scope['printer_id'],
        'operationId': 'operation',
        'productId': 'product',
        'reportId': reportId,
        'product': scope['product'],
        'lot': 'LOCAL:$reportId',
        'quantity': '2.5',
        'unit': 'kg',
        'producedAt': now.toIso8601String(),
        'expiresAt': null,
        'provisional': true,
        'reprintOf': null,
        'reprintReason': null,
      };
      var sends = 0;
      String? printed;
      LocalBridge bridge() => LocalBridge(
        journal: CommandJournal(File('${tls.directory.path}/journal')),
        security: session,
        printerSend: (_, bytes) async {
          sends++;
          printed = ascii.decode(bytes);
        },
      );
      var runtime = bridge();
      final server = CompanionServer(
        verify: (_) async => {},
        run: (_, _, _) async => {},
        runProductionLabel: (body, origin) =>
            runtime.runProductionLabel(body, origin),
      );
      final client = HttpClient(context: tls.clientContext);
      Future<(int, Map<String, dynamic>)> send(
        Map<String, dynamic> value, {
        SigningFixture? signer,
        String? lease,
      }) async {
        final message = jsonEncode({
          'version': 1,
          'leaseId': leaseId,
          'commandId': value['commandId'],
          'payloadHash': hardwarePayloadHash(value),
          'origin': scope['origin'],
        });
        final request = await client.postUrl(
          Uri.parse('https://127.0.0.1:${server.port}/v1/production-label'),
        );
        request.headers.set('Origin', scope['origin']);
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'lease': lease ?? token,
            'payload': value,
            'message': message,
            'signature': (signer ?? kds).signature(message),
          }),
        );
        final response = await request.close();
        return (
          response.statusCode,
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
        );
      }

      try {
        await server.start(
          securityContext: tls.serverContext,
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        for (final changed in [
          {...payload, 'productId': 'foreign'},
          {...payload, 'quantity': '10.000001'},
          {...payload, 'lot': 'native-lot'},
          {
            ...payload,
            'expiresAt': now.add(const Duration(days: 1)).toIso8601String(),
          },
          {
            ...payload,
            'producedAt': now
                .subtract(const Duration(days: 1))
                .toIso8601String(),
          },
        ]) {
          expect((await send(changed)).$1, 403);
        }
        expect((await send(payload, signer: foreign)).$1, 403);
        expect(
          (await send(
            payload,
            lease: authority.token({...grant, 'kind': 'erp'}),
          )).$1,
          403,
        );
        expect(sends, 0);
        final first = await send(payload);
        expect(first.$1, 200);
        final signed = jsonDecode(first.$2['resultJson']);
        expect(signed['leaseId'], leaseId);
        expect(signed['reportId'], reportId);
        expect(signed['outcome'], 'unknown');
        expect(signed['delivery'], 'sent_unconfirmed');
        expect(
          OfflineGrantVerifier(
            keys: {},
            org: 'org',
            location: 'location',
            companion: 'companion',
          ).verifySignature(
            companion.jwk,
            first.$2['resultJson'],
            first.$2['signature'],
          ),
          isTrue,
        );
        expect(printed, contains('NOT ERP ACCEPTED'));
        expect(printed, contains('PROVISIONAL OFFLINE'));
        expect(printed, contains('LOCAL:'));
        expect(printed, contains('ciocolata'));
        await runtime.close();
        runtime = bridge();
        expect((await send(payload)).$1, 200);
        expect(sends, 1);
        const reprintId = '00000000-0000-4000-8000-000000000004';
        expect((await send({...payload, 'commandId': reprintId})).$1, 409);
        expect(
          (await send({
            ...payload,
            'commandId': reprintId,
            'reprintOf': commandId,
            'reprintReason': 'Damaged',
            'quantity': '3',
          })).$1,
          409,
        );
        expect(
          (await send({
            ...payload,
            'commandId': reprintId,
            'reprintOf': commandId,
            'reprintReason': 'Damaged',
          })).$1,
          200,
        );
        expect(sends, 2);
        const nextReport = '00000000-0000-4000-8000-000000000005';
        expect(
          (await send({
            ...payload,
            'commandId': '00000000-0000-4000-8000-000000000006',
            'reportId': nextReport,
            'lot': 'LOCAL:$nextReport',
          })).$1,
          409,
        );
        expect(sends, 2);
        now = now.add(const Duration(days: 3));
        expect((await send(payload)).$1, 403);
        expect(sends, 2);
        expect(
          await File('${tls.directory.path}/journal').readAsString(),
          isNot(contains(token)),
        );
      } finally {
        client.close(force: true);
        await server.close();
        await runtime.close();
        await tls.directory.delete(recursive: true);
      }
    },
  );
}
