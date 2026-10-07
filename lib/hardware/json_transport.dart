import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'connection.dart';

abstract interface class JsonTransport {
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]);
}

/// Explicit trust for one configured terminal certificate. Never disables TLS
/// verification globally; even certificates signed by a CA must match the pin.
class PinnedTerminalTransport implements JsonTransport {
  PinnedTerminalTransport(this.endpoint, this.certificateSha256) {
    if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(certificateSha256)) {
      throw ArgumentError('A terminal certificate SHA-256 pin is required');
    }
  }
  final LanEndpoint endpoint;
  final String certificateSha256;
  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    if (!['GET', 'POST'].contains(method) || !path.startsWith('/pos/v1/')) {
      throw ArgumentError('Invalid terminal operation');
    }
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 5);
    client.badCertificateCallback = (cert, host, port) =>
        host == endpoint.host &&
        port == endpoint.port &&
        sha256.convert(cert.der).toString() == certificateSha256.toLowerCase();
    try {
      final request = await client
          .openUrl(
            method,
            Uri(
              scheme: 'https',
              host: endpoint.host,
              port: endpoint.port,
              path: path,
            ),
          )
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        throw HttpException('Terminal HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        bytes.addAll(chunk);
        if (bytes.length > 262144) {
          throw const FormatException('Terminal response too large');
        }
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid terminal JSON');
      }
      return value;
    } finally {
      client.close(force: true);
    }
  }
}
