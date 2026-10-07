import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:chimera_companion/security/sale_admission.dart';
import 'package:chimera_companion/security/offline_grant.dart';
import 'package:chimera_companion/security/payment_rejection.dart';

void main() {
  final now = DateTime.utc(2026, 10, 4, 12);
  final facts = <String, dynamic>{
    'currency': 'RON',
    'paymentMethod': 'card',
    'totalMinor': 500,
    'lines': [
      {
        'name': 'Coffee',
        'quantity': '1',
        'unitPriceMinor': 500,
        'grossTotalMinor': 500,
        'vatRate': 21,
      },
    ],
  };
  Map<String, dynamic> result() => {
    'operation': 'saleAuthorize',
    'outcome': 'succeeded',
    'commandId': 'sale-1',
    'companion': 'ecr-peer',
    'operatorId': 'alice',
    'posId': 'pos-1',
    'saleAdmission': {
      'org': 'org-1',
      'location': 'copou',
      'receiptCompanion': 'ecr-peer',
      'saleId': 'sale-1',
      'operatorId': 'alice',
      'posId': 'pos-1',
      'amountMinor': 500,
      'currency': 'RON',
      'receiptHash': saleFactsHash(facts),
      'startedAt': now.subtract(const Duration(minutes: 1)).toIso8601String(),
      'expiresAt': now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
    },
  };
  Map<String, dynamic> verify(
    Map<String, dynamic> response, {
    bool signed = true,
    String? hash,
  }) => verifySaleAdmission(
    proof: {'resultJson': jsonEncode(response), 'signature': 'fixture'},
    org: 'org-1',
    location: 'copou',
    receiptCompanion: 'ecr-peer',
    saleId: 'sale-1',
    operatorId: 'alice',
    posId: 'pos-1',
    amountMinor: 500,
    currency: 'RON',
    now: now,
    receiptHash: hash,
    verifySignature: (_, _) => signed,
  );

  test('payment peer accepts only signed matching ECR admission', () {
    expect(verify(result())['saleId'], 'sale-1');
    expect(() => verify(result(), signed: false), throwsFormatException);
    for (final field in [
      'operation',
      'outcome',
      'commandId',
      'companion',
      'operatorId',
      'posId',
    ]) {
      final value = result()..[field] = 'wrong';
      expect(() => verify(value), throwsFormatException, reason: field);
    }
  });
  test('payment-start proof binds the terminal and payment command to the original sale',(){
    final source=result();
    Map<String,dynamic> paymentResult()=>{...source,'operation':'salePaymentStart','commandId':'payment-1',
      'paymentAdmission':{...source['saleAdmission'] as Map,'lifecycleVersion':1,'phase':'payment_started','paymentCommandId':'payment-1','paymentCompanion':'terminal-peer'}};
    Map<String,dynamic> check(Map<String,dynamic> value,{bool signed=true})=>verifySaleAdmission(
      proof:{'resultJson':jsonEncode(value),'signature':'fixture'},org:'org-1',location:'copou',receiptCompanion:'ecr-peer',saleId:'sale-1',operatorId:'alice',posId:'pos-1',
      amountMinor:500,currency:'RON',receiptHash:saleFactsHash(facts),paymentCommandId:'payment-1',paymentCompanion:'terminal-peer',now:now,verifySignature:(_,_)=>signed);
    expect(check(paymentResult())['paymentCommandId'],'payment-1');
    expect(()=>check(paymentResult(),signed:false),throwsFormatException);
    for(final field in ['lifecycleVersion','paymentCommandId','paymentCompanion','saleId','receiptHash','operatorId','posId','currency','phase']) {
      final value=paymentResult();(value['paymentAdmission'] as Map)[field]='wrong';
      expect(()=>check(value),throwsFormatException,reason:field);
    }
    expect(()=>check(source),throwsFormatException);
  });
  test(
    'inconsistent amounts or invalid lines fail before payment admission',
    () {
      expect(
        () => saleFacts({...facts, 'totalMinor': 501}),
        throwsFormatException,
      );
      final valid = Map<String, dynamic>.from((facts['lines'] as List).single);
      for (final changes in [
        {'quantity': '0'},
        {'quantity': '-1'},
        {'quantity': 1},
        {'grossTotalMinor': 500.1},
        {'unitPriceMinor': -1},
        {'vatRate': double.nan},
      ]) {
        expect(
          () => saleFacts({
            ...facts,
            'lines': [
              {...valid, ...changes},
            ],
          }),
          throwsFormatException,
        );
      }
    },
  );
  test('scope, identity, amount and currency cannot be replayed', () {
    for (final field in [
      'org',
      'location',
      'receiptCompanion',
      'saleId',
      'operatorId',
      'posId',
      'amountMinor',
      'currency',
    ]) {
      final value = result();
      (value['saleAdmission'] as Map)[field] = field == 'amountMinor'
          ? 501
          : 'wrong';
      expect(() => verify(value), throwsFormatException, reason: field);
    }
  });
  test('expired and future authorizations fail closed', () {
    final expired = result();
    (expired['saleAdmission'] as Map)['expiresAt'] = now.millisecondsSinceEpoch;
    expect(() => verify(expired), throwsFormatException);
    final future = result();
    (future['saleAdmission'] as Map)['startedAt'] = now
        .add(const Duration(seconds: 1))
        .toIso8601String();
    expect(() => verify(future), throwsFormatException);
    final unbounded = result();
    (unbounded['saleAdmission'] as Map)['expiresAt'] = now
        .add(const Duration(days: 8))
        .millisecondsSinceEpoch;
    expect(() => verify(unbounded), throwsFormatException);
  });
  test('receipt must match the originally authorized financial facts', () {
    expect(verify(result(), hash: saleFactsHash(facts))['amountMinor'], 500);
    expect(
      () => verify(
        result(),
        hash: saleFactsHash({
          ...facts,
          'lines': [
            {...(facts['lines'] as List).single, 'name': 'Other'},
          ],
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => verify(result(), hash: saleFactsHash({...facts, 'cui': 'RO12345'})),
      throwsFormatException,
    );
  });
  test('real ES256 signature rejects edited data and a different peer key', () {
    Uint8List bytes(BigInt value) => Uint8List.fromList(
      List.generate(
        32,
        (index) => ((value >> (8 * (31 - index))) & BigInt.from(255)).toInt(),
      ),
    );
    final domain = ECDomainParameters('prime256v1');
    // Fixed synthetic test identity; no production device key is involved.
    final secret = BigInt.from(7), public = domain.G * BigInt.from(7);
    Map<String, dynamic> jwk(ECPoint point) => {
      'kty': 'EC',
      'crv': 'P-256',
      'x': base64UrlEncode(bytes(point.x!.toBigInteger()!)),
      'y': base64UrlEncode(bytes(point.y!.toBigInteger()!)),
    };
    final random = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i + 1))));
    final signer = ECDSASigner(SHA256Digest())
      ..init(
        true,
        ParametersWithRandom(
          PrivateKeyParameter(ECPrivateKey(secret, domain)),
          random,
        ),
      );
    final message = jsonEncode(result());
    final signature =
        signer.generateSignature(Uint8List.fromList(utf8.encode(message)))
            as ECSignature;
    final encoded = base64UrlEncode([
      ...bytes(signature.r),
      ...bytes(signature.s),
    ]);
    final verifier = OfflineGrantVerifier(
      keys: {},
      org: 'org-1',
      location: 'copou',
      companion: 'payment-peer',
    );
    Map<String, dynamic> run(String text, Map<String, dynamic> key) =>
        verifySaleAdmission(
          proof: {'resultJson': text, 'signature': encoded},
          org: 'org-1',
          location: 'copou',
          receiptCompanion: 'ecr-peer',
          saleId: 'sale-1',
          operatorId: 'alice',
          posId: 'pos-1',
          amountMinor: 500,
          currency: 'RON',
          now: now,
          receiptHash: saleFactsHash(facts),
          verifySignature: (text, sig) =>
              verifier.verifySignature(key, text, sig),
        );
    expect(run(message, jwk(public!))['amountMinor'], 500);
    expect(
      () => run(message.replaceFirst('500', '501'), jwk(public)),
      throwsFormatException,
    );
    expect(
      () => run(message, jwk((domain.G * BigInt.from(8))!)),
      throwsFormatException,
    );
    // Exercise the cross-Companion payment-start contract with an actual
    // signature, not the callback stub used by field-validation fixtures.
    final original=result();
    final paymentMessage=jsonEncode({...original,'operation':'salePaymentStart','commandId':'payment-1',
      'paymentAdmission':{...original['saleAdmission'] as Map,'lifecycleVersion':1,
        'phase':'payment_started','paymentCommandId':'payment-1','paymentCompanion':'payment-peer'}});
    final paymentSignature=signer.generateSignature(Uint8List.fromList(utf8.encode(paymentMessage))) as ECSignature;
    final paymentEncoded=base64UrlEncode([...bytes(paymentSignature.r),...bytes(paymentSignature.s)]);
    Map<String,dynamic> verifyPayment(String text,Map<String,dynamic> key,{String terminal='payment-peer',String command='payment-1'})=>verifySaleAdmission(
      proof:{'resultJson':text,'signature':paymentEncoded},org:'org-1',location:'copou',receiptCompanion:'ecr-peer',saleId:'sale-1',operatorId:'alice',posId:'pos-1',
      amountMinor:500,currency:'RON',now:now,receiptHash:saleFactsHash(facts),paymentCommandId:command,paymentCompanion:terminal,
      verifySignature:(value,sig)=>verifier.verifySignature(key,value,sig));
    expect(verifyPayment(paymentMessage,jwk(public))['paymentCommandId'],'payment-1');
    expect(()=>verifyPayment(paymentMessage.replaceFirst('payment-1','payment-2'),jwk(public)),throwsFormatException);
    expect(()=>verifyPayment(paymentMessage,jwk((domain.G*BigInt.from(8))!)),throwsFormatException);
    expect(()=>verifyPayment(paymentMessage,jwk(public),terminal:'other-terminal'),throwsFormatException);
    expect(()=>verifyPayment(paymentMessage,jwk(public),command:'other-payment'),throwsFormatException);
    final paymentAdmission={...original['saleAdmission'] as Map<String,dynamic>,
      'lifecycleVersion':1,'phase':'payment_started','paymentCommandId':'payment-1','paymentCompanion':'payment-peer'};
    final rejectionMessage=jsonEncode({'operation':'payment','outcome':'rejected','commandId':'payment-1','companion':'payment-peer','operatorId':'alice','posId':'pos-1',
      'paymentRejection':{'org':'org-1','location':'copou','receiptCompanion':'ecr-peer','saleId':'sale-1','paymentCommandId':'payment-1','amountMinor':500,'currency':'RON','outcome':'rejected','source':'terminal_journal'}});
    final rejectionSignature=signer.generateSignature(Uint8List.fromList(utf8.encode(rejectionMessage))) as ECSignature;
    final rejectionEncoded=base64UrlEncode([...bytes(rejectionSignature.r),...bytes(rejectionSignature.s)]);
    void checkRejection(String text,Map<String,dynamic> key)=>verifyPaymentRejection(
      proof:{'resultJson':text,'signature':rejectionEncoded},admission:paymentAdmission,
      verifySignature:(value,sig)=>verifier.verifySignature(key,value,sig));
    expect(()=>checkRejection(rejectionMessage,jwk(public)),returnsNormally);
    expect(()=>checkRejection(rejectionMessage.replaceFirst('500','501'),jwk(public)),throwsFormatException);
    expect(()=>checkRejection(rejectionMessage,jwk((domain.G*BigInt.from(8))!)),throwsFormatException);
  });
}
