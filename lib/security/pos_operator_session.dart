import 'dart:convert';
import 'offline_grant.dart';
import 'operator_assertion.dart';

bool samePosKey(dynamic a, dynamic b) =>
    a is Map &&
    b is Map &&
    ['kty', 'crv', 'x', 'y'].every((field) => a[field] == b[field]);

/// Validates the original POS login, not a second Companion login. Command
/// nonce, signature, payload and current pair/operator grants are checked by
/// OfflineSession. Reuse of this bounded login evidence is intentional.
int verifyPosOperatorSession({
  required Map<String, dynamic> evidence,
  required Map<String, dynamic> pair,
  required Map<String, dynamic> operator,
  required Map<String, dynamic> policy,
  required OfflineGrantVerifier verifier,
  required List<String> revoked,
  required String origin,
  required DateTime now,
}) {
  late Map<String, dynamic> session;
  late String credentialId;
  Map<String, dynamic>? assertion;
  String? challenge;
  if (evidence['type'] == 'authority' && evidence['token'] is String) {
    session = verifier.verify(
      evidence['token'] as String,
      kind: 'pos_operator_login',
      now: now,
    );
    if (session['session_id'] is! String ||
        (session['session_id'] as String).isEmpty ||
        session['auth_at'] is! int ||
        session['auth_at'] > session['iat'] ||
        session['exp'] - session['auth_at'] > offlineLeaseSeconds ||
        session['sub'] != operator['sub'] ||
        session['version'] != pair['version']) {
      throw const FormatException('Invalid POS login session');
    }
    credentialId = session['credential'] as String;
  } else if (evidence['type'] == 'passkey' &&
      evidence['challenge'] is String &&
      evidence['assertion'] is Map) {
    challenge = evidence['challenge'] as String;
    if (challenge.length > 4096) {
      throw const FormatException('POS session too large');
    }
    session =
        jsonDecode(utf8.decode(decodeBase64Url(challenge)))
            as Map<String, dynamic>;
    if (session['v'] != 1 ||
        session['kind'] != 'pos_operator_session' ||
        session['org'] != pair['org'] ||
        session['location'] != pair['location'] ||
        session['operator'] != operator['sub'] ||
        session['nonce'] is! String ||
        decodeBase64Url(session['nonce'] as String).length != 32) {
      throw const FormatException('Wrong POS login binding');
    }
    assertion = Map<String, dynamic>.from(evidence['assertion']);
    credentialId = assertion['id'] as String;
  } else {
    throw const FormatException('POS login evidence required');
  }
  final seconds = now.millisecondsSinceEpoch ~/ 1000;
  final iat = session['iat'], exp = session['exp'];
  if (iat is! int ||
      exp is! int ||
      iat > seconds + 5 ||
      exp <= seconds ||
      exp <= iat ||
      exp - iat > offlineLeaseSeconds ||
      session['pos'] != pair['pos'] ||
      session['origin'] != origin ||
      !samePosKey(session['cnf']?['jwk'], pair['cnf']['jwk'])) {
    throw const FormatException('Expired or mismatched POS login');
  }
  final credential = (policy['credentials'] as List)
      .where((item) => item['id'] == credentialId)
      .firstOrNull;
  if (credential == null || revoked.contains(credentialId)) {
    throw const FormatException('POS credential revoked');
  }
  var expiry = exp * 1000;
  if (credential['expiresAt'] != null) {
    final credentialExpiry = DateTime.parse(credential['expiresAt'] as String);
    if (!credentialExpiry.isAfter(now)) {
      throw const FormatException('POS credential expired');
    }
    if (credentialExpiry.millisecondsSinceEpoch < expiry) {
      expiry = credentialExpiry.millisecondsSinceEpoch;
    }
  }
  if (assertion != null) {
    // This is a reusable session certificate, not a new login assertion.
    // Its exact time/scope/key bounds were signed by the phone. The POS already
    // enforces the login counter; each command has independent anti-replay.
    verifyOperatorAssertion(
      assertion,
      Map<String, dynamic>.from(credential),
      policy,
      challenge!,
      origin,
      0,
      verifyCounter: false,
    );
  }
  return [
    expiry,
    (pair['exp'] as int) * 1000,
    (operator['exp'] as int) * 1000,
  ].reduce((a, b) => a < b ? a : b);
}
