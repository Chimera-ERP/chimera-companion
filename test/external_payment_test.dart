import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/security/external_payment.dart';

void main() {
  Map<String,dynamic> valid() => {
    'checkoutPolicy': {'card_mode':'external'}, 'paymentMethod':'card',
    'operatorId':'user-1', 'totalMinor':500, 'currency':'RON',
    'externalPaymentConfirmation': {'saleId':'sale-1','operatorId':'user-1',
      'amountMinor':500,'currency':'RON','confirmed':true},
  };
  test('explicit external policy accepts a sale-bound human confirmation', () {
    expect(externalPaymentReference('sale-1',valid()),'operator-confirmed:sale-1');
    expect(externalPaymentReference('sale-1',{}),isNull);
  });
  test('rejects integrated fallback, changed identity/amount and prior payment', () {
    for(final change in [
      {'checkoutPolicy':{'card_mode':'integrated'}},
      {'checkoutPolicy':null}, {'operatorId':'other'}, {'totalMinor':501},
      {'currency':'EUR'}, {'paymentMethod':'cash'}, {'paymentCommandId':'uncertain'},
      {'paymentEvidence':'bank-proof'},
    ]) {
      expect(()=>externalPaymentReference('sale-1',{...valid(),...change}),throwsFormatException);
    }
    expect(()=>externalPaymentReference('sale-2',valid()),throwsFormatException);
  });
}
