import 'dart:convert';

/// Verifies a terminal-journal rejection, not a generic handler rejection.
/// The caller chooses the trusted terminal key from its equipment roster.
void verifyPaymentRejection({required Map<String,dynamic> proof,
  required Map<String,dynamic> admission,
  required bool Function(String,String) verifySignature}) {
  final message=proof['resultJson'],signature=proof['signature'];
  if(message is! String||message.length>100000||signature is! String||!verifySignature(message,signature)) {
    throw const FormatException('Invalid terminal rejection signature');
  }
  final result=jsonDecode(message);
  final rejection=result is Map?result['paymentRejection']:null;
  if(admission['lifecycleVersion']!=1||admission['phase']!='payment_started'||
    result is! Map||rejection is! Map||result['operation']!='payment'||result['outcome']!='rejected'||
    result['companion']!=admission['paymentCompanion']||result['commandId']!=admission['paymentCommandId']||
    result['operatorId']!=admission['operatorId']||result['posId']!=admission['posId']||
    rejection['source']!='terminal_journal'||rejection['outcome']!='rejected'||
    ['org','location','saleId','receiptCompanion','amountMinor','currency','paymentCommandId'].any((key)=>rejection[key]!=admission[key])) {
    throw const FormatException('Terminal rejection does not match admitted payment');
  }
}
