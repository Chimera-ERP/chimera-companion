import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/tls_provisioning.dart';
import 'package:chimera_companion/local_tls.dart';
import 'tls_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TlsFixture fixture;
  late String chain;
  late String key;
  setUp(() async {
    fixture = await TlsFixture.create();
    chain = await File(
      '${fixture.directory.path}/certificate.pem',
    ).readAsString();
    chain += await File('${fixture.directory.path}/ca.pem').readAsString();
    key = await File(
      '${fixture.directory.path}/private-key.pem',
    ).readAsString();
  });
  tearDown(() async {
    await fixture.directory.delete(recursive: true);
  });
  test(
    'reverse proxy advertises external HTTPS while validating separate backend TLS',
    () async {
      await File('${fixture.directory.path}/pending.json').writeAsString(
        jsonEncode({'hostname': 'companion.example.test', 'privateKey': key}),
      );
      final provisioning = TlsProvisioning(fixture.directory);
      await provisioning.install(
        'companion.example.test',
        chain,
        reverseProxy: 'https://proxy.example.test',
      );
      final loaded = await LocalTls.load(fixture.directory);
      expect(loaded.origin.origin, 'https://proxy.example.test');
      expect(loaded.allowedHosts, {
        'proxy.example.test',
        'companion.example.test',
      });
      for (final invalid in [
        'http://proxy.example.test',
        'https://user:pass@proxy.example.test',
        'https://proxy.example.test/path',
        'https://proxy.example.test?token=secret',
      ]) {
        await expectLater(
          provisioning.install(
            'companion.example.test',
            chain,
            reverseProxy: invalid,
          ),
          throwsFormatException,
        );
      }
      expect(
        (await LocalTls.load(fixture.directory)).origin.origin,
        'https://proxy.example.test',
      );
    },
  );

  test('valid certificate matches local key and exact SAN', () {
    expect(
      TlsProvisioning.validate(
        'https://companion.example.test:8765',
        chain,
        key,
      ),
      isA<DateTime>(),
    );
    expect(
      () => TlsProvisioning.validate(
        'https://wrong.example.test:8765',
        chain,
        key,
      ),
      throwsFormatException,
    );
    expect(
      () => TlsProvisioning.validate(
        'http://companion.example.test:8765',
        chain,
        key,
      ),
      throwsFormatException,
    );
    expect(
      () => TlsProvisioning.validate(
        'https://companion.example.test:8765',
        chain,
        key,
        now: DateTime.now().add(const Duration(days: 3)),
      ),
      throwsFormatException,
    );
  });
  test('invalid replacement preserves previously installed bundle', () async {
    await File('${fixture.directory.path}/pending.json').writeAsString(
      jsonEncode({'hostname': 'companion.example.test', 'privateKey': key}),
    );
    final provisioning = TlsProvisioning(fixture.directory);
    await provisioning.install('companion.example.test', chain);
    final bundle = File('${fixture.directory.path}/bundle.json');
    final before = await bundle.readAsString();
    await expectLater(
      provisioning.install('companion.example.test', 'not a certificate'),
      throwsFormatException,
    );
    expect(await bundle.readAsString(), before);
    await expectLater(
      provisioning.install('other.example.test', chain),
      throwsFormatException,
    );
    expect(await bundle.readAsString(), before);
  });
}
