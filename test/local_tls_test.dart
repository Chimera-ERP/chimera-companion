import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/local_tls.dart';
import 'tls_fixture.dart';

void main() {
  late TlsFixture tls;
  setUp(() async => tls = await TlsFixture.create());
  tearDown(() async => tls.directory.delete(recursive: true));

  test('missing provisioning fails closed', () async {
    await File('${tls.directory.path}/private-key.pem').delete();
    await expectLater(
      LocalTls.load(tls.directory),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'provisioning rejects plaintext and malformed endpoint origins',
    () async {
      for (final origin in [
        'http://localhost:8765',
        'https://localhost:8765/path',
        'https://user:secret@localhost:8765',
        'https://localhost:8765?token=secret',
        'https://localhost:8766',
      ]) {
        await File(
          '${tls.directory.path}/endpoint.json',
        ).writeAsString('{"origin":"$origin"}');
        await expectLater(LocalTls.load(tls.directory), throwsFormatException);
      }
    },
  );

  test(
    'TLS listener accepts trusted HTTPS and rejects untrusted TLS and HTTP',
    () async {
      final provisioned = await LocalTls.load(tls.directory);
      var calls = 0;
      final server = CompanionServer(
        verify: (_) async => throw StateError('Not authorized'),
        run: (_, _, _) async {
          calls++;
          return {};
        },
      );
      await server.start(
        securityContext: provisioned.context,
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      final trusted = HttpClient(context: tls.clientContext);
      final untrusted = HttpClient(
        context: SecurityContext(withTrustedRoots: false),
      );
      final plain = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      try {
        final request = await trusted.getUrl(
          Uri.parse('https://localhost:${server.port}/health'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
        await expectLater(
          untrusted.getUrl(
            Uri.parse('https://localhost:${server.port}/health'),
          ),
          throwsA(isA<HandshakeException>()),
        );
        await expectLater(() async {
          final request = await plain.getUrl(
            Uri.parse('http://localhost:${server.port}/health'),
          );
          await (await request.close()).drain<void>();
        }(), throwsA(isA<Exception>()));
        expect(calls, 0);
      } finally {
        trusted.close(force: true);
        untrusted.close(force: true);
        plain.close(force: true);
        await server.close();
      }
    },
  );
}
