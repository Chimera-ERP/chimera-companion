import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'device_identity.dart';
import 'offline_grant.dart';
import 'operator_assertion.dart';
import 'sale_admission.dart';
import 'payment_rejection.dart';
import '../erp_commands.dart';

typedef RefreshTrust = Future<Map<String, dynamic>> Function();

/// All local command authorization is decided here, before hardware dispatch.
class OfflineSession {
  OfflineSession({
    required this.file,
    required this.org,
    required this.location,
    required this.companion,
    required this.identity,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final File file;
  final String org, location, companion;
  final DeviceIdentity identity;
  final DateTime Function() _now;
  static bool _sameKey(dynamic a, dynamic b) =>
      a is Map &&
      b is Map &&
      ['kty', 'crv', 'x', 'y'].every((field) => a[field] == b[field]);
  Map<String, dynamic> _trust = {};
  late Map<String, dynamic> _publicKey;
  AuthorizationClock _clock = AuthorizationClock();
  final Map<String, DateTime> _challenges = {};
  final Set<String> _locallyRevoked = {};
  Map<String, dynamic> _operatorSessions = {};
  Map<String, dynamic> _operatorCounters = {};
  Future<void> _writing = Future.value();

  Future<void> restore() async {
    _publicKey = await identity.publicKey();
    if (await file.exists()) {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _trust = Map<String, dynamic>.from(data['trust'] ?? {});
      _clock = AuthorizationClock(
        highWater: DateTime.tryParse(data['highWater'] ?? ''),
      );
      _locallyRevoked.addAll(List<String>.from(data['revoked'] ?? []));
      _operatorSessions = Map<String, dynamic>.from(
        data['operatorSessions'] ?? {},
      );
      _operatorCounters = Map<String, dynamic>.from(
        data['operatorCounters'] ?? {},
      );
    }
  }

  Future<void> _persist() {
    final serialized = jsonEncode({
      'trust': _trust,
      'highWater': _clock.highWater?.toIso8601String(),
      'revoked': _locallyRevoked.toList(),
      'operatorSessions': _operatorSessions,
      'operatorCounters': _operatorCounters,
    });
    final operation = _writing.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.next');
      await temporary.writeAsString(serialized, flush: true);
      await temporary.rename(file.path);
    });
    _writing = operation.catchError((_) {});
    return operation;
  }

  Future<void> updateTrust(Map<String, dynamic> data) async {
    if (data['signing_keys'] is! List || data['peers'] is! List) {
      throw const FormatException('Invalid trust response');
    }
    _trust = data;
    await _persist();
  }

  Future<void> revokeLocally(String pos) async {
    _locallyRevoked.add(pos);
    await _persist();
  }

  OfflineGrantVerifier get _verifier => OfflineGrantVerifier(
    keys: {
      for (final key in (_trust['signing_keys'] as List? ?? []))
        key['kid'] as String: Map<String, dynamic>.from(key),
    },
    org: org,
    location: location,
    companion: companion,
  );
  Map<String, dynamic> _pair(String token, DateTime now) {
    final claims = _verifier.verify(token, kind: 'pair', now: now);
    final peer = (_trust['peers'] as List? ?? [])
        .where((p) => p['pos_id'] == claims['pos'])
        .firstOrNull;
    if (_locallyRevoked.contains(claims['pos']) ||
        (peer != null &&
            (peer['revoked'] == true ||
                peer['version'] != claims['version'])) ||
        claims['sub'] != claims['pos'] ||
        !_sameKey(claims['peer']['jwk'], _publicKey)) {
      throw const FormatException('Pairing revoked or mismatched');
    }
    return claims;
  }

  Future<Map<String, Object?>> challenge(String lease) async {
    final now = _clock.check(_now());
    _pair(lease, now);
    _challenges.removeWhere((_, expiry) => !expiry.isAfter(now));
    if (_challenges.length >= 64) {
      throw StateError('Too many pending challenges');
    }
    final random = Random.secure();
    final nonce = base64Url
        .encode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    _challenges[nonce] = now.add(const Duration(seconds: 60));
    await _persist();
    final message = jsonEncode({
      'companion': companion,
      'challenge': nonce,
      'expiresAt': _challenges[nonce]!.millisecondsSinceEpoch,
      'operatorLoginProof': true,
    });
    return {'message': message, 'signature': await identity.sign(message)};
  }

  Future<Map<String, dynamic>> authorize(
    Map<String, dynamic> body,
    String origin,
  ) async {
    final now = _clock.check(_now());
    final pair = _pair(body['lease'] as String, now);
    final message = body['message'] as String;
    final proof = jsonDecode(message) as Map<String, dynamic>;
    final nonce = proof['challenge'];
    final expiry = _challenges[nonce];
    if (expiry == null ||
        !expiry.isAfter(now) ||
        proof['companion'] != companion ||
        proof['method'] != 'POST' ||
        proof['origin'] != origin ||
        proof['commandId'] is! String ||
        (proof['commandId'] as String).length > 150 ||
        (proof['commandId'] as String).isEmpty ||
        proof['operation'] is! String ||
        !(pair['operations'] as List).contains(proof['operation']) ||
        !_verifier.verifySignature(
          Map<String, dynamic>.from(pair['cnf']['jwk']),
          message,
          body['signature'] as String,
        )) {
      throw const FormatException('Invalid command proof');
    }
    final payloadJson = body['payloadJson'] as String;
    if (proof['payloadHash'] !=
        sha256.convert(utf8.encode(payloadJson)).toString()) {
      throw const FormatException('Changed command payload');
    }
    if (!['status', 'history'].contains(proof['operation'])) {
      final operator = _verifier.verify(
        body['operatorGrant'] as String,
        kind: 'operator',
        now: now,
      );
      if (operator['pos'] != pair['pos'] ||
          operator['version'] != pair['version'] ||
          !_sameKey(operator['cnf']['jwk'], pair['cnf']['jwk']) ||
          !(operator['operations'] as List).contains(proof['operation'])) {
        throw const FormatException('Operator permission required');
      }
      final policy = operator['webauthn'];
      if (policy is! Map ||
          policy['credentials'] is! List ||
          policy['origin'] != origin) {
        throw const FormatException('Trusted operator passkey policy required');
      }
      _operatorSessions.removeWhere(
        (_, value) => (value['exp'] as int) <= now.millisecondsSinceEpoch,
      );
      var sessionId = proof['operatorSession'] as String?;
      final saved = sessionId == null ? null : _operatorSessions[sessionId];
      final revoked = List<String>.from(_trust['revoked_credentials'] ?? []);
      if (saved != null) {
        final currentCredential = (policy['credentials'] as List)
            .where((item) => item['id'] == saved['credential'])
            .firstOrNull;
        if (currentCredential != null &&
            currentCredential['expiresAt'] != null &&
            !DateTime.parse(
              currentCredential['expiresAt'] as String,
            ).isAfter(now)) {
          _operatorSessions.remove(sessionId);
          throw const FormatException('Operator credential expired');
        }
      }
      if (saved == null ||
          saved['pos'] != pair['pos'] ||
          saved['operator'] != operator['sub'] ||
          saved['version'] != pair['version'] ||
          saved['origin'] != origin ||
          !(policy['credentials'] as List).any(
            (credential) => credential['id'] == saved['credential'],
          ) ||
          revoked.contains(saved['credential'])) {
        final assertion = body['operatorAssertion'];
        Map<String, dynamic>? login;
        if (body['operatorLoginProof'] is String) {
          login = _verifier.verify(
            body['operatorLoginProof'] as String,
            kind: 'operator_login',
            now: now,
          );
          if (login['sub'] != operator['sub'] ||
              login['pos'] != pair['pos'] ||
              login['version'] != pair['version'] ||
              login['origin'] != origin ||
              !_sameKey(login['cnf']['jwk'], pair['cnf']['jwk']) ||
              (login['exp'] as int) - (login['iat'] as int) > 300) {
            throw const FormatException('Invalid verified operator login');
          }
        }
        if (login == null && assertion is! Map<String, dynamic>) {
          throw const FormatException('Operator authentication required');
        }
        final credential = (policy['credentials'] as List)
            .where(
              (item) =>
                  item['id'] ==
                  (login != null
                      ? login['credential']
                      : (assertion as Map)['id']),
            )
            .firstOrNull;
        if (credential == null || revoked.contains(credential['id'])) {
          throw const FormatException('Active operator credential required');
        }
        final credentialExpiry = credential['expiresAt'] == null
            ? null
            : DateTime.parse(credential['expiresAt'] as String);
        if (credentialExpiry != null && !credentialExpiry.isAfter(now)) {
          throw const FormatException('Operator credential expired');
        }
        final prior = (_operatorCounters[credential['id']] as int?) ?? 0;
        final initial = (credential['counter'] as num).toInt();
        final counter = login != null
            ? (prior > initial ? prior : initial)
            : verifyOperatorAssertion(
                assertion as Map<String, dynamic>,
                Map<String, dynamic>.from(credential),
                Map<String, dynamic>.from(policy),
                nonce as String,
                origin,
                prior > initial ? prior : initial,
              );
        _operatorCounters[credential['id']] = counter;
        if (_operatorSessions.length >= 64) {
          throw const FormatException('Too many operator sessions');
        }
        sessionId = base64UrlEncode(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        ).replaceAll('=', '');
        var grantExpiry = (operator['exp'] as int) * 1000;
        if (credentialExpiry != null &&
            credentialExpiry.millisecondsSinceEpoch < grantExpiry) {
          grantExpiry = credentialExpiry.millisecondsSinceEpoch;
        }
        final sessionExpiry = now
            .add(const Duration(hours: 8))
            .millisecondsSinceEpoch;
        _operatorSessions[sessionId] = {
          'pos': pair['pos'],
          'operator': operator['sub'],
          'credential': credential['id'],
          'version': pair['version'],
          'origin': origin,
          'exp': sessionExpiry < grantExpiry ? sessionExpiry : grantExpiry,
        };
      }
      proof['operatorSession'] = sessionId;
      proof['authorizationExpires'] = [
        (pair['exp'] as int) * 1000,
        (operator['exp'] as int) * 1000,
        _operatorSessions[sessionId]['exp'] as int,
      ].reduce((a, b) => a < b ? a : b);
      proof['operatorId'] = operator['sub'];
      proof['operatorName'] = operator['operatorName'];
      proof['checkoutPolicy'] = operator['checkoutPolicy'];
      proof['canResetOperatorReport'] =
          operator['canResetOperatorReport'] == true;
    }
    _challenges.remove(nonce);
    await _persist();
    return {
      ...proof,
      'pos': pair['pos'],
      if (proof['authorizationExpires'] == null)
        'authorizationExpires': (pair['exp'] as int) * 1000,
      'payload': jsonDecode(payloadJson),
      'payloadHash': proof['payloadHash'],
    };
  }

  Future<Map<String, Object?>> result(
    Map<String, Object?> result,
    String payloadHash,
  ) async {
    final message = jsonEncode({
      ...result,
      'companion': companion,
      'payloadHash': payloadHash,
    });
    return {'resultJson': message, 'signature': await identity.sign(message)};
  }

  Map<String, dynamic> verifyErp(String ticket, Map<String, dynamic> payload) {
    final grant = _verifier.verify(
      ticket,
      kind: 'erp',
      now: _clock.check(_now()),
    );
    if (grant['pos'] != 'erp' ||
        grant['payloadHash'] != hardwarePayloadHash(payload) ||
        !_sameKey(grant['peer']['jwk'], _publicKey) ||
        ![
          'nonFiscal',
          'xReport',
          'zReport',
          'rawEcr',
          'companionDiagnostics',
          'companionRefreshAuthorization',
        ].contains((grant['operations'] as List).single)) {
      throw const FormatException('Invalid ERP hardware authorization');
    }
    return grant;
  }

  Future<Map<String, Object?>> paymentEvidence(
    String command,
    Map<String, dynamic> payload,
    String reference,
  ) async {
    final message = jsonEncode({
      'org': org,
      'location': location,
      'paymentCompanion': companion,
      'paymentCommandId': command,
      'receiptCompanion': payload['receiptCompanionId'],
      'receiptCommandId': payload['receiptCommandId'],
      'saleId': payload['saleId'],
      'amountMinor': payload['amountMinor'],
      'currency': payload['currency'],
      'reference': reference,
      'outcome': 'succeeded',
    });
    return {
      'paymentEvidence': message,
      'paymentSignature': await identity.sign(message),
    };
  }

  bool receiptCompanionExists(String id) => (_trust['equipment'] as List? ?? [])
      .any((item) => item['kind'] == 'ecr' && item['companion_id'] == id);

  Map<String, dynamic> verifySaleAuthorization(
    Map<String, dynamic> proof,
    Map<String, dynamic> payload, {
    required bool fiscalReceipt,
  }) {
    final receiptOwner = fiscalReceipt ? companion : payload['receiptCompanionId'];
    final owner = (_trust['equipment'] as List? ?? []).where((item) =>
      item['kind'] == 'ecr' && item['companion_id'] == receiptOwner).firstOrNull;
    if (owner == null || payload['operatorId'] is! String || payload['posId'] is! String ||
        payload['saleId'] is! String ||
        (fiscalReceipt ? payload['totalMinor'] : payload['amountMinor']) is! int ||
        payload['currency'] is! String) {
      throw const FormatException('Trusted sale authorization required');
    }
    return verifySaleAdmission(
      proof: proof, org: org, location: location,
      receiptCompanion: receiptOwner as String, saleId: payload['saleId'],
      operatorId: payload['operatorId'], posId: payload['posId'],
      amountMinor: fiscalReceipt ? (payload['paymentMethod']=='card'?receiptCardAmount(payload):payload['totalMinor']) : payload['amountMinor'],
      currency: payload['currency'], now: _clock.check(_now()),
      receiptHash: fiscalReceipt ? saleFactsHash(payload) : null,
      verifySignature: (message, signature) => _verifier.verifySignature(
        Map<String, dynamic>.from(owner['public_jwk']), message, signature),
    );
  }

  bool trustedPaymentCompanion(String id)=>(_trust['equipment'] as List? ?? []).any((item)=>item['kind']=='payment'&&item['companion_id']==id);
  String? loyaltyPaymentCode(String host,int port)=>(_trust['equipment'] as List? ?? []).where((item)=>item['kind']=='ecr'&&item['companion_id']==companion&&item['host']==host&&item['port']==port).firstOrNull?['loyalty_payment_code'] as String?;
  void verifyFidelity(String token,String id,Map<String,dynamic> payload){
    final grant=_verifier.verify(token,kind:'fidelity',now:_clock.check(_now()));
    final coinsAmount=(payload['payments'] as List).where((p)=>p['method']=='loyalty').fold<int>(0,(sum,p)=>sum+(p['amountMinor'] as int));
    if(grant['commandId']!=id||grant['pos']!=payload['posId']||grant['sub']!=payload['operatorId']||grant['receiptHash']!=saleFactsHash(payload)||grant['loyaltyMinor']!=coinsAmount)throw const FormatException('Coins approval does not match this receipt');
  }

  void verifyRecordedPaymentRejection(Map<String,dynamic> proof,Map<String,dynamic> admission) {
    final owner=(_trust['equipment'] as List? ?? []).where((item)=>item['kind']=='payment'&&item['companion_id']==admission['paymentCompanion']).firstOrNull;
    if(owner==null)throw const FormatException('Trusted terminal required');
    verifyPaymentRejection(proof:proof,admission:admission,
      verifySignature:(message,signature)=>_verifier.verifySignature(Map<String,dynamic>.from(owner['public_jwk']),message,signature));
  }

  Map<String,dynamic> verifyPaymentStart(Map<String,dynamic> proof,Map<String,dynamic> payload,String commandId,String receiptHash) {
    final receiptOwner=payload['receiptCompanionId'];
    final owner=(_trust['equipment'] as List? ?? []).where((item)=>item['kind']=='ecr'&&item['companion_id']==receiptOwner).firstOrNull;
    if(owner==null||receiptOwner is! String||payload['operatorId'] is! String||payload['posId'] is! String||payload['saleId'] is! String||payload['amountMinor'] is! int||payload['currency'] is! String)throw const FormatException('Trusted payment-start authorization required');
    return verifySaleAdmission(proof:proof,org:org,location:location,receiptCompanion:receiptOwner,
      saleId:payload['saleId'],operatorId:payload['operatorId'],posId:payload['posId'],amountMinor:payload['amountMinor'],currency:payload['currency'],
      receiptHash:receiptHash,paymentCommandId:commandId,paymentCompanion:companion,now:_clock.check(_now()),
      verifySignature:(message,signature)=>_verifier.verifySignature(Map<String,dynamic>.from(owner['public_jwk']),message,signature));
  }

  String verifyPayment(
    String message,
    String signature,
    String receipt,
    Map<String, dynamic> payload,
  ) {
    final value = jsonDecode(message) as Map<String, dynamic>;
    final owner = (_trust['equipment'] as List? ?? [])
        .where(
          (item) =>
              item['kind'] == 'payment' &&
              item['companion_id'] == value['paymentCompanion'],
        )
        .firstOrNull;
    if (owner == null ||
        value['org'] != org ||
        value['location'] != location ||
        value['receiptCompanion'] != companion ||
        value['receiptCommandId'] != receipt ||
        value['saleId'] != payload['saleId'] ||
        value['saleId'] != receipt ||
        value['paymentCommandId'] != payload['paymentCommandId'] ||
        value['amountMinor'] != receiptCardAmount(payload) ||
        value['currency'] != payload['currency'] ||
        value['outcome'] != 'succeeded' ||
        value['reference'] is! String ||
        (value['reference'] as String).isEmpty ||
        !_verifier.verifySignature(
          Map<String, dynamic>.from(owner['public_jwk']),
          message,
          signature,
        )) {
      throw const FormatException('Payment evidence does not match this sale');
    }
    return value['reference'] as String;
  }

  bool ownsEquipment(String kind, String host, int port) =>
      (_trust['equipment'] as List? ?? []).any(
        (item) =>
            item['kind'] == kind &&
            item['host'] == host &&
            item['port'] == port &&
            item['companion_id'] == companion,
      );
}
