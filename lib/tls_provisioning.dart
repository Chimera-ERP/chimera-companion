import 'dart:convert';
import 'dart:io';
import 'package:basic_utils/basic_utils.dart';
import 'package:flutter/foundation.dart';

Map<String, String> _generate(String hostname) {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final key = pair.privateKey as RSAPrivateKey;
  return {
    'hostname': hostname,
    'privateKey': CryptoUtils.encodeRSAPrivateKeyToPem(key),
    'csr': X509Utils.generateRsaCsrPem(
      {'CN': hostname},
      key,
      pair.publicKey as RSAPublicKey,
      san: [hostname],
    ),
  };
}

/// The private bundle is committed by one rename; readers never observe a
/// certificate paired with a different generation's key or endpoint.
class TlsProvisioning {
  TlsProvisioning(this.directory);
  final Directory directory;
  Future<void>? _writing;

  static String hostname(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.length > 253 ||
        !value.contains('.') ||
        !value
            .split('.')
            .every(
              (label) => RegExp(
                r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
              ).hasMatch(label),
            )) {
      throw const FormatException(
        'Introdu un hostname DNS valid, fără protocol sau port.',
      );
    }
    return value;
  }

  Future<String> createCsr(String name) async {
    if (_writing != null) throw StateError('Configurarea TLS este în curs.');
    final host = hostname(name);
    String? result;
    _writing = () async {
      await directory.create(recursive: true);
      final pending = File('${directory.path}/pending.json');
      if (await pending.exists()) {
        final existing =
            jsonDecode(await pending.readAsString()) as Map<String, dynamic>;
        if (existing['hostname'] == host) {
          result = existing['csr'] as String;
          return;
        }
      }
      final generated = await compute(_generate, host);
      final staging = File('${directory.path}/pending.next');
      await staging.writeAsString(jsonEncode(generated), flush: true);
      await staging.rename(pending.path);
      result = generated['csr'];
    }();
    try {
      await _writing;
      return result!;
    } finally {
      _writing = null;
    }
  }

  static DateTime validate(
    String origin,
    String chain,
    String privateKey, {
    DateTime? now,
  }) {
    final endpoint = Uri.parse(origin);
    if (endpoint.scheme != 'https' ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/') ||
        endpoint.port != 8765) {
      throw const FormatException(
        'Adresa locală trebuie să fie HTTPS pe portul 8765.',
      );
    }
    final pems = RegExp(
      r'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----',
    ).allMatches(chain).map((match) => match.group(0)!).toList();
    if (pems.isEmpty || chain.contains('PRIVATE KEY')) {
      throw const FormatException('Lanț de certificate invalid.');
    }
    final leaf = X509Utils.x509CertificateFromPem(pems.first);
    final validity = leaf.tbsCertificate!.validity;
    final current = (now ?? DateTime.now()).toUtc();
    if (current.isBefore(validity.notBefore) ||
        !current.isBefore(validity.notAfter)) {
      throw const FormatException(
        'Certificatul a expirat sau nu este încă valabil.',
      );
    }
    if (!(leaf.tbsCertificate?.extensions?.subjectAlternativNames ?? []).any(
      (name) => name.toLowerCase() == endpoint.host.toLowerCase(),
    )) {
      throw const FormatException(
        'Certificatul nu acoperă hostname-ul configurat.',
      );
    }
    final key = CryptoUtils.rsaPrivateKeyFromPem(privateKey);
    if (key.modulus != X509Utils.getModulusFromRSAX509Pem(pems.first)) {
      throw const FormatException(
        'Certificatul nu aparține cheii generate pe acest Companion.',
      );
    }
    for (var i = 0; i + 1 < pems.length; i++) {
      if (!X509Utils.checkX509Signature(pems[i], parent: pems[i + 1])) {
        throw const FormatException('Lanțul intermediar nu este valid.');
      }
    }
    SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(chain))
      ..usePrivateKeyBytes(utf8.encode(privateKey));
    return validity.notAfter;
  }

  static Uri proxyOrigin(String raw) {
    final uri = Uri.parse(raw);
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException(
        'Endpoint proxy HTTPS fără path sau credențiale necesar.',
      );
    }
    hostname(uri.host);
    return uri;
  }

  Future<DateTime> install(
    String name,
    String chain, {
    String? reverseProxy,
  }) async {
    if (_writing != null) throw StateError('Configurarea TLS este în curs.');
    final host = hostname(name);
    final advertised = reverseProxy == null
        ? null
        : proxyOrigin(reverseProxy).origin;
    DateTime? expires;
    _writing = () async {
      final pending =
          jsonDecode(
                await File('${directory.path}/pending.json').readAsString(),
              )
              as Map<String, dynamic>;
      if (pending['hostname'] != host) {
        throw const FormatException(
          'Generează întâi CSR-ul pentru acest hostname.',
        );
      }
      final origin = 'https://$host:8765';
      expires = validate(origin, chain, pending['privateKey'] as String);
      final bundle = {
        'version': 1,
        'origin': origin,
        'advertisedOrigin': ?advertised,
        'certificate': chain,
        'privateKey': pending['privateKey'],
        'expiresAt': expires!.toUtc().toIso8601String(),
      };
      final staging = File('${directory.path}/bundle.next');
      await staging.writeAsString(jsonEncode(bundle), flush: true);
      await staging.rename('${directory.path}/bundle.json');
    }();
    try {
      await _writing;
      return expires!;
    } finally {
      _writing = null;
    }
  }
}
