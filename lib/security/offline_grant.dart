import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

const offlineLeaseSeconds = 7 * 24 * 60 * 60;

Uint8List decodeBase64Url(String value) =>
    base64Url.decode(base64Url.normalize(value));
BigInt _integer(List<int> bytes) =>
    bytes.fold(BigInt.zero, (value, byte) => (value << 8) | BigInt.from(byte));

/// Public keys are provisioned from authenticated Chimera HTTPS, never a request.
class OfflineGrantVerifier {
  OfflineGrantVerifier({
    required this.keys,
    required this.org,
    required this.location,
    required this.companion,
  });
  final Map<String, Map<String, dynamic>> keys;
  final String org, location, companion;

  bool verifySignature(
    Map<String, dynamic> jwk,
    String message,
    String encodedSignature,
  ) {
    try {
      if (jwk['kty'] != 'EC' || jwk['crv'] != 'P-256' || jwk.containsKey('d')) {
        return false;
      }
      final x = decodeBase64Url(jwk['x'] as String),
          y = decodeBase64Url(jwk['y'] as String);
      final signature = decodeBase64Url(encodedSignature);
      if (x.length != 32 || y.length != 32 || signature.length != 64) {
        return false;
      }
      final domain = ECDomainParameters('prime256v1');
      final point = domain.curve.createPoint(_integer(x), _integer(y));
      final verifier = ECDSASigner(SHA256Digest())
        ..init(
          false,
          PublicKeyParameter<ECPublicKey>(ECPublicKey(point, domain)),
        );
      return verifier.verifySignature(
        Uint8List.fromList(utf8.encode(message)),
        ECSignature(
          _integer(signature.sublist(0, 32)),
          _integer(signature.sublist(32)),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> verify(
    String token, {
    required String kind,
    required DateTime now,
  }) {
    if (token.length > 16000) throw const FormatException('Invalid grant');
    final parts = token.split('.');
    if (parts.length != 3) throw const FormatException('Invalid grant');
    final header =
        jsonDecode(utf8.decode(decodeBase64Url(parts[0])))
            as Map<String, dynamic>;
    final key = keys[header['kid']];
    if (header['alg'] != 'ES256' ||
        header['typ'] != 'JWT' ||
        key == null ||
        !verifySignature(key, '${parts[0]}.${parts[1]}', parts[2])) {
      throw const FormatException('Untrusted grant');
    }
    final claims =
        jsonDecode(utf8.decode(decodeBase64Url(parts[1])))
            as Map<String, dynamic>;
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    final exp = claims['exp'], iat = claims['iat'], nbf = claims['nbf'];
    if (claims['iss'] != 'chimera-companion' ||
        claims['kind'] != kind ||
        claims['org'] != org ||
        claims['location'] != location ||
        claims['aud'] != companion ||
        claims['companion'] != companion ||
        exp is! int ||
        iat is! int ||
        nbf is! int ||
        exp <= seconds ||
        iat > seconds + 5 ||
        nbf > seconds + 5 ||
        exp <= iat ||
        exp - iat > offlineLeaseSeconds ||
        claims['operations'] is! List ||
        claims['pos'] is! String ||
        claims['sub'] is! String ||
        claims['version'] is! int ||
        claims['version'] < 1) {
      throw const FormatException('Expired or mismatched grant');
    }
    return claims;
  }
}

/// Checked before any command. Persistence must finish before a dispatch.
class AuthorizationClock {
  AuthorizationClock({DateTime? highWater}) : this._(highWater);
  AuthorizationClock._(this._highWater);
  DateTime? _highWater;
  DateTime? get highWater => _highWater;
  DateTime check(DateTime now) {
    final previous = _highWater;
    if (previous != null &&
        now.isBefore(previous.subtract(const Duration(seconds: 5)))) {
      throw StateError('Clock regression requires online reauthorization');
    }
    if (previous == null || now.isAfter(previous)) _highWater = now;
    return _highWater!;
  }
}
