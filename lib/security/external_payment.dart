// A human confirmation is never bank evidence. Policy comes from the verified
// ERP grant, and identity is injected by the authenticated local server.
import 'sale_admission.dart';
String? externalPaymentReference(String saleId, Map<String, dynamic> payload) {
  final confirmation = payload['externalPaymentConfirmation'];
  if (confirmation == null) return null;
  final policy = payload['checkoutPolicy'];
  if (policy is! Map || policy['card_mode'] != 'external' ||
      payload['paymentMethod'] != 'card' || confirmation is! Map ||
      confirmation['saleId'] != saleId ||
      confirmation['operatorId'] != payload['operatorId'] ||
      payload['operatorId'] is! String || (payload['operatorId'] as String).isEmpty ||
      confirmation['amountMinor'] != receiptCardAmount(payload) ||
      confirmation['currency'] != payload['currency'] ||
      confirmation['confirmed'] != true ||
      payload['paymentEvidence'] != null || payload['paymentCommandId'] != null) {
    throw const FormatException('External card confirmation is not authorized for this sale');
  }
  return 'operator-confirmed:$saleId';
}
