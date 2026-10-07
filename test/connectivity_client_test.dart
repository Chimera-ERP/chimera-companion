import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/connectivity_client.dart';
import 'package:chimera_companion/tls_provisioning.dart';
import 'package:chimera_companion/security/device_identity.dart';
import 'tls_fixture.dart';

class TestIdentity extends DeviceIdentity {
  @override
  Future<Map<String, dynamic>> publicKey() async => {
    'kty': 'EC',
    'crv': 'P-256',
  };
  @override
  Future<String> sign(String message) async => 'signed-device-proof';
}

void main() {
  test(
    'initial LAN discovery prefers physical Wi-Fi over VPN and rejects ambiguity',
    () {
      expect(
        initialLanAddress([
          (name: 'tun0', ip: '10.0.0.2'),
          (name: 'wlan0', ip: '192.168.1.50'),
        ]).ip,
        '192.168.1.50',
      );
      expect(
        () => initialLanAddress([(name: 'tun0', ip: '10.0.0.2')]),
        throwsStateError,
      );
      expect(
        () => initialLanAddress([
          (name: 'wlan0', ip: '192.168.1.50'),
          (name: 'wlan1', ip: '192.168.2.50'),
        ]),
        throwsStateError,
      );
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'companion-connectivity-test-',
    );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
    'invalid/public/loopback addresses are rejected before enrollment or network',
    () async {
      final client = ConnectivityClient(
        provisioning: TlsProvisioning(directory),
      );
      for (final ip in [
        '127.0.0.1',
        '8.8.8.8',
        '::1',
        '169.254.169.254',
        'not an ip',
      ]) {
        await expectLater(client.configure(ip), throwsFormatException);
      }
      expect(await directory.list().isEmpty, isTrue);
    },
  );
  test(
    'automatic certificate provisioning requires existing enrollment',
    () async {
      await expectLater(
        ConnectivityClient(
          provisioning: TlsProvisioning(directory),
        ).configure('192.168.1.144'),
        throwsStateError,
      );
      expect(await directory.list().isEmpty, isTrue);
    },
  );
  test(
    'LAN interface follows DHCP but never silently selects an ambiguous network',
    () {
      expect(
        selectLanAddress(
          [
            (name: 'wlan0', ip: '192.168.1.150'),
            (name: 'tun0', ip: '10.0.0.2'),
          ],
          '192.168.1.144',
          'wlan0',
        ).ip,
        '192.168.1.150',
      );
      expect(
        () => selectLanAddress(
          [
            (name: 'wlan0', ip: '192.168.1.150'),
            (name: 'tun0', ip: '10.0.0.2'),
          ],
          '192.168.1.144',
          null,
        ),
        throwsStateError,
      );
      expect(
        () => selectLanAddress(
          [(name: 'tun0', ip: '10.0.0.2')],
          '192.168.1.144',
          'wlan0',
        ),
        throwsStateError,
      );
    },
  );
  Future<String> cached({
    bool expired = false,
    String serviceUrl = 'https://cert.example.test',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final host =
        'c-${sha256.convert(utf8.encode('device-a')).toString().substring(0, 24)}.companions.chimera.example.test';
    final claims = {
      'sub': 'device-a',
      'kind': 'transport',
      'aud': 'chimera-connectivity',
      'zone': 'chimera.example.test',
      'iat': now - 10,
      'exp': expired ? now - 1 : now + 3600,
    };
    final ticket =
        'header.${base64UrlEncode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.signature';
    FlutterSecureStorage.setMockInitialValues({
      'erp_pairing_v1': jsonEncode({
        'erp_url': 'https://erp.example.test',
        'device_id': 'device-a',
        'token': 'enrolled-token',
      }),
      'connectivity_authorization_v1': jsonEncode({
        'erp_url': 'https://erp.example.test',
        'device_id': 'device-a',
        'authorization': {
          'mode': 'managed',
          'hostname': host,
          'service_url': serviceUrl,
          'ticket': ticket,
        },
      }),
    });
    await File('${directory.path}/bundle.json').writeAsString(
      jsonEncode({
        'origin': 'https://$host:8765',
        'expiresAt': DateTime.now()
            .add(const Duration(days: 60))
            .toIso8601String(),
      }),
    );
    return host;
  }

  test(
    'ERP unavailable uses unexpired saved authorization without requesting a new certificate',
    () async {
      final host = await cached();
      final operations = <String>[];
      final client = ConnectivityClient(
        provisioning: TlsProvisioning(directory),
        identity: TestIdentity(),
        request: (uri, payload, token) async {
          if (uri.host == 'erp.example.test') {
            throw const SocketException('offline');
          }
          final message =
              jsonDecode(payload['message'] as String) as Map<String, dynamic>;
          operations.add(message['operation'] as String);
          expect(message['ip'], '192.168.1.150');
          expect(payload['signature'], 'signed-device-proof');
          return {'hostname': host};
        },
      );
      await client.configure(
        '192.168.1.150',
        onlyIfDue: true,
        interfaceName: 'wlan0',
      );
      expect(operations, ['address']);
    },
  );
  test(
    'same-origin connectivity prefix survives ERP outage and does not route through API',
    () async {
      final host = await cached(
        serviceUrl: 'https://erp.example.test/connectivity',
      );
      final paths = <String>[];
      final client = ConnectivityClient(
        provisioning: TlsProvisioning(directory),
        identity: TestIdentity(),
        request: (uri, payload, token) async {
          paths.add(uri.path);
          if (uri.path.startsWith('/api/')) {
            throw const SocketException('ERP down');
          }
          expect(uri.path, '/connectivity/v1/address');
          return {'hostname': host};
        },
      );
      await client.configure('192.168.1.99', onlyIfDue: true);
      expect(paths.last, '/connectivity/v1/address');
    },
  );
  test(
    'expired saved authorization prevents DNS updates while ERP is unavailable',
    () async {
      await cached(expired: true);
      var serviceCalls = 0;
      final client = ConnectivityClient(
        provisioning: TlsProvisioning(directory),
        identity: TestIdentity(),
        request: (uri, payload, token) async {
          if (uri.host == 'erp.example.test') {
            throw const SocketException('offline');
          }
          serviceCalls++;
          return {};
        },
      );
      await expectLater(
        client.configure('192.168.1.150', onlyIfDue: true),
        throwsFormatException,
      );
      expect(serviceCalls, 0);
    },
  );
  test(
    'explicit ERP rejection clears cached credentials instead of falling back',
    () async {
      await cached();
      final client = ConnectivityClient(
        provisioning: TlsProvisioning(directory),
        identity: TestIdentity(),
        request: (uri, payload, token) async {
          throw const HttpException('403');
        },
      );
      await expectLater(
        client.configure('192.168.1.150', onlyIfDue: true),
        throwsA(isA<HttpException>()),
      );
      expect(
        await const FlutterSecureStorage().read(
          key: 'connectivity_authorization_v1',
        ),
        isNull,
      );
    },
  );
  for (final invalid in [false, true]) {
    test(
      invalid
          ? 'failed certificate renewal preserves old bundle'
          : 'certificate due for renewal is installed from a local-key CSR',
      () async {
        final host = await cached();
        final fixture = await TlsFixture.create(hostname: host);
        try {
          final key = await File(
            '${fixture.directory.path}/private-key.pem',
          ).readAsString();
          final csr = await File(
            '${fixture.directory.path}/request.pem',
          ).readAsString();
          final chain =
              await File(
                '${fixture.directory.path}/certificate.pem',
              ).readAsString() +
              await File('${fixture.directory.path}/ca.pem').readAsString();
          await File('${directory.path}/pending.json').writeAsString(
            jsonEncode({'hostname': host, 'privateKey': key, 'csr': csr}),
          );
          final provisioner = TlsProvisioning(directory);
          await provisioner.install(host, chain);
          final bundle = File('${directory.path}/bundle.json');
          final before = await bundle.readAsString();
          final operations = <String>[];
          final client = ConnectivityClient(
            provisioning: provisioner,
            identity: TestIdentity(),
            request: (uri, payload, token) async {
              if (uri.host == 'erp.example.test') {
                throw const SocketException('offline');
              }
              expect(jsonEncode(payload), isNot(contains('PRIVATE KEY')));
              final message =
                  jsonDecode(payload['message'] as String)
                      as Map<String, dynamic>;
              operations.add(message['operation'] as String);
              if (message['operation'] == 'certificate') {
                expect(message['csr'], csr);
                return {
                  'hostname': host,
                  'certificate': invalid ? 'invalid certificate' : chain,
                };
              }
              return {'hostname': host};
            },
          );
          if (invalid) {
            await expectLater(
              client.configure('192.168.1.144', onlyIfDue: true),
              throwsFormatException,
            );
            expect(await bundle.readAsString(), before);
          } else {
            final expiry = await client.configure(
              '192.168.1.144',
              onlyIfDue: true,
            );
            expect(expiry.isAfter(DateTime.now()), isTrue);
            final installed =
                jsonDecode(await bundle.readAsString()) as Map<String, dynamic>;
            expect(installed['privateKey'], key);
            expect(installed['certificate'], chain);
          }
          expect(operations, ['address', 'certificate']);
        } finally {
          await fixture.directory.delete(recursive: true);
        }
      },
    );
  }
}
