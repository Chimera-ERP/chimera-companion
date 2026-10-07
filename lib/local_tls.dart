import 'dart:convert';
import 'dart:io';
import 'tls_provisioning.dart';

/// Provisioned per installation in the application's private storage.
/// Trust is checked by the browser; loading a PEM is not proof of browser trust.
class LocalTls {
  LocalTls(this.context, this.origin, {Set<String>? allowedHosts})
    : allowedHosts = allowedHosts ?? {origin.host};

  final SecurityContext context;
  final Uri origin;
  final Set<String> allowedHosts;

  static Future<LocalTls> load(Directory directory) async {
    final bundle = File('${directory.path}/bundle.json');
    if (await bundle.exists()) {
      final value =
          jsonDecode(await bundle.readAsString()) as Map<String, dynamic>;
      if (value['version'] != 1) {
        throw const FormatException('Versiune TLS necunoscută.');
      }
      TlsProvisioning.validate(
        value['origin'] as String,
        value['certificate'] as String,
        value['privateKey'] as String,
      );
      final context = SecurityContext(withTrustedRoots: false)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
        ..useCertificateChainBytes(utf8.encode(value['certificate'] as String))
        ..usePrivateKeyBytes(utf8.encode(value['privateKey'] as String));
      final backend = Uri.parse(value['origin'] as String);
      final advertised = value['advertisedOrigin'] == null
          ? backend
          : TlsProvisioning.proxyOrigin(value['advertisedOrigin'] as String);
      return LocalTls(
        context,
        advertised,
        allowedHosts: {backend.host, advertised.host},
      );
    }
    final config = File('${directory.path}/endpoint.json');
    final certificate = File('${directory.path}/certificate.pem');
    final key = File('${directory.path}/private-key.pem');
    if (!await config.exists() ||
        !await certificate.exists() ||
        !await key.exists()) {
      throw const FileSystemException(
        'Configurează certificatul HTTPS local înainte de conectarea POS.',
      );
    }
    final value =
        jsonDecode(await config.readAsString()) as Map<String, dynamic>;
    final origin = Uri.parse(value['origin'] as String);
    if (origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/') ||
        origin.port != 8765) {
      throw const FormatException('Adresa HTTPS locală nu este validă.');
    }
    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;
    TlsProvisioning.validate(
      origin.origin,
      await certificate.readAsString(),
      await key.readAsString(),
    );
    context.useCertificateChainBytes(await certificate.readAsBytes());
    context.usePrivateKeyBytes(await key.readAsBytes());
    return LocalTls(context, origin);
  }
}
