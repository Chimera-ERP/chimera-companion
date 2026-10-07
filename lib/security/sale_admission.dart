import 'dart:convert';
import '../hardware/command_journal.dart';

Map<String, dynamic> saleFacts(Map<String, dynamic> payload) {
  if (payload['currency'] != 'RON' ||
      payload['totalMinor'] is! int ||
      payload['totalMinor'] <= 0 ||
      payload['totalMinor'] > 99999999 ||
      !['cash', 'card','loyalty'].contains(payload['paymentMethod']) ||
      payload['lines'] is! List ||
      (payload['lines'] as List).isEmpty) {
    throw const FormatException('Invalid sale facts');
  }
  var total = 0;
  for (final line in payload['lines'] as List) {
    if (line is! Map ||
        line['grossTotalMinor'] is! int ||
        line['grossTotalMinor'] < 0 ||
        line['unitPriceMinor'] is! int ||
        line['unitPriceMinor'] < 0 ||
        line['name'] is! String ||
        (line['name'] as String).trim().isEmpty ||
        line['quantity'] is! String ||
        !RegExp(r'^\d+(?:\.\d{1,6})?$').hasMatch(line['quantity']) ||
        double.parse(line['quantity']) <= 0 ||
        line['vatRate'] is! num ||
        !(line['vatRate'] as num).isFinite ||
        line['vatRate'] < 0 ||
        line['vatRate'] > 100) {
      throw const FormatException('Invalid fiscal line before payment');
    }
    total += line['grossTotalMinor'] as int;
  }
  if (total != payload['totalMinor']) {
    throw const FormatException(
      'Fiscal lines do not match authorized payment amount',
    );
  }
  if(payload['settlementVersion']==2){
    final payments=payload['payments'];
    if(payments is! List||payments.isEmpty||payments.length>3||payments.any((p)=>p is! Map||!['cash','card','loyalty'].contains(p['method'])||p['amountMinor'] is! int||p['amountMinor']<=0)||payments.fold<int>(0,(sum,p)=>sum+(p['amountMinor'] as int))!=total||payments.map((p)=>p['method']).toSet().length!=payments.length||!['fiscal','nonfiscal'].contains(payload['documentMode']))throw const FormatException('Invalid versioned settlement');
    final methods=payments.map((p)=>p['method']).toSet();
    if(methods.contains('cash')&&methods.contains('card')||payload['paymentMethod']!=(methods.contains('card')?'card':methods.contains('cash')?'cash':'loyalty'))throw const FormatException('Unsupported payment combination');
  }
  return {
    'currency': payload['currency'],
    'paymentMethod': payload['paymentMethod'],
    'totalMinor': payload['totalMinor'],
    'lines': payload['lines'],
    'cui': payload['cui'],
    if(payload['settlementVersion']==2) ...{'settlementVersion':2,'payments':payload['payments'],'documentMode':payload['documentMode']},
  };
}
int receiptCardAmount(Map<String,dynamic> payload)=>payload['settlementVersion']==2?((payload['payments'] as List).where((p)=>p['method']=='card').firstOrNull?['amountMinor'] as int? ?? 0):payload['totalMinor'] as int;

String saleFactsHash(Map<String, dynamic> payload) =>
    CommandJournal.fingerprint('', 'saleFacts', saleFacts(payload));

/// Verifies the original ECR Companion response, not a browser-created claim.
/// The caller supplies the signature verifier and key from its trusted roster.
Map<String, dynamic> verifySaleAdmission({
  required Map<String, dynamic> proof,
  required String org,
  required String location,
  required String receiptCompanion,
  required String saleId,
  required String operatorId,
  required String posId,
  required int amountMinor,
  required String currency,
  required DateTime now,
  required bool Function(String message, String signature) verifySignature,
  String? receiptHash,
  String? paymentCommandId,
  String? paymentCompanion,
}) {
  if((paymentCommandId==null)!=(paymentCompanion==null)||paymentCommandId==''||paymentCompanion=='')throw const FormatException('Incomplete payment-start identity');
  final message = proof['resultJson'], signature = proof['signature'];
  if (message is! String ||
      message.length > 100000 ||
      signature is! String ||
      !verifySignature(message, signature)) {
    throw const FormatException('Invalid sale authorization signature');
  }
  final result = jsonDecode(message);
  final admission = result is Map ? result[paymentCommandId==null?'saleAdmission':'paymentAdmission'] : null;
  if (result is! Map ||
      admission is! Map ||
      result['operation'] != (paymentCommandId==null?'saleAuthorize':'salePaymentStart') ||
      result['outcome'] != 'succeeded' ||
      result['commandId'] != (paymentCommandId??saleId) ||
      result['companion'] != receiptCompanion ||
      result['operatorId'] != operatorId ||
      result['posId'] != posId ||
      admission['org'] != org ||
      admission['location'] != location ||
      admission['receiptCompanion'] != receiptCompanion ||
      admission['saleId'] != saleId ||
      admission['operatorId'] != operatorId ||
      admission['posId'] != posId ||
      admission['amountMinor'] != amountMinor ||
      admission['currency'] != currency ||
      (paymentCommandId!=null&&(admission['lifecycleVersion']!=1||admission['phase']!='payment_started'||admission['paymentCommandId']!=paymentCommandId||admission['paymentCompanion']!=paymentCompanion)) ||
      admission['receiptHash'] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(admission['receiptHash']) ||
      (receiptHash != null && admission['receiptHash'] != receiptHash) ||
      admission['expiresAt'] is! int ||
      admission['expiresAt'] <= now.millisecondsSinceEpoch) {
    throw const FormatException('Sale authorization does not match this sale');
  }
  final started = admission['startedAt'] is String
      ? DateTime.tryParse(admission['startedAt'])
      : null;
  if (started == null ||
      started.isAfter(now) ||
      admission['expiresAt'] <= started.millisecondsSinceEpoch ||
      admission['expiresAt'] >
          started.add(const Duration(days: 7)).millisecondsSinceEpoch) {
    throw const FormatException('Invalid sale authorization lifetime');
  }
  return Map<String, dynamic>.from(admission);
}
