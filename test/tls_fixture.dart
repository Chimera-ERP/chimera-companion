import 'dart:io';

class TlsFixture {
  TlsFixture._(this.directory);
  final Directory directory;

  static Future<TlsFixture> create({String? hostname}) async {
    final directory = await Directory.systemTemp.createTemp('companion-tls-');
    await File('${directory.path}/extensions.cnf').writeAsString(
      'basicConstraints=critical,CA:FALSE\n'
      'keyUsage=critical,digitalSignature,keyEncipherment\n'
      'extendedKeyUsage=serverAuth\n'
      'subjectAltName=DNS:localhost,DNS:companion.example.test,IP:127.0.0.1${hostname == null ? '' : ',DNS:$hostname'}\n',
    );
    final commands = [
      [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        '${directory.path}/ca-key.pem',
        '-out',
        '${directory.path}/ca.pem',
        '-days',
        '1',
        '-subj',
        '/CN=Ephemeral test CA',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
      ],
      [
        'req',
        '-new',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        '${directory.path}/private-key.pem',
        '-out',
        '${directory.path}/request.pem',
        '-subj',
        '/CN=${hostname ?? 'localhost'}',
      ],
      [
        'x509',
        '-req',
        '-in',
        '${directory.path}/request.pem',
        '-CA',
        '${directory.path}/ca.pem',
        '-CAkey',
        '${directory.path}/ca-key.pem',
        '-CAcreateserial',
        '-out',
        '${directory.path}/certificate.pem',
        '-days',
        '1',
        '-extfile',
        '${directory.path}/extensions.cnf',
      ],
    ];
    for (final arguments in commands) {
      final result = await Process.run('openssl', arguments);
      if (result.exitCode != 0) {
        await directory.delete(recursive: true);
        throw StateError('Cannot create ephemeral TLS test fixture');
      }
    }
    await File(
      '${directory.path}/endpoint.json',
    ).writeAsString('{"origin":"https://localhost:8765"}');
    return TlsFixture._(directory);
  }

  SecurityContext get serverContext => SecurityContext(withTrustedRoots: false)
    ..useCertificateChain('${directory.path}/certificate.pem')
    ..usePrivateKey('${directory.path}/private-key.pem');

  SecurityContext get clientContext =>
      SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates('${directory.path}/ca.pem');
}
