import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/security/payment_rejection.dart';
import 'package:chimera_companion/security/sale_lifecycle.dart';

void main() {
  final admission=SaleLifecycle.admitted({'org':'org','location':'copou','saleId':'sale','receiptCompanion':'ecr','operatorId':'alice','posId':'pos','receiptHash':'a'*64,'amountMinor':500,'currency':'RON'})
    .beginPayment(commandId:'pay',companion:'terminal',amountMinor:500,currency:'RON').toJson();
  Map<String,dynamic> result()=>{'operation':'payment','outcome':'rejected','commandId':'pay','companion':'terminal','operatorId':'alice','posId':'pos',
    'paymentRejection':{'org':'org','location':'copou','saleId':'sale','receiptCompanion':'ecr','paymentCommandId':'pay','amountMinor':500,'currency':'RON','outcome':'rejected','source':'terminal_journal'}};
  void check(Map<String,dynamic> value,{bool signed=true})=>verifyPaymentRejection(proof:{'resultJson':jsonEncode(value),'signature':'fixture'},admission:admission,verifySignature:(_,_)=>signed);
  test('matching verified terminal refusal can release a persisted unpaid sale',(){
    expect(()=>check(result()),returnsNormally);
    final cancelled=SaleLifecycle.restore(SaleLifecycle.restore(admission).rejectPayment().toJson());
    expect(cancelled.abandoned,isTrue);
    expect(()=>cancelled.requireReceiptState(paymentMethod:'card',external:false,paymentCommandId:'pay'),throwsStateError);
  });
  test('unknown, preflight rejection, wrong actor or peer never releases payment',(){
    expect(()=>check(result(),signed:false),throwsFormatException);
    expect(()=>check(result()..remove('paymentRejection')),throwsFormatException);
    for(final field in ['operation','outcome','commandId','companion','operatorId','posId']) {
      expect(()=>check(result()..[field]='wrong'),throwsFormatException,reason:field);
    }
    for(final field in ['org','location','saleId','receiptCompanion','paymentCommandId','amountMinor','currency','outcome','source']) {
      final value=result();(value['paymentRejection'] as Map)[field]='wrong';
      expect(()=>check(value),throwsFormatException,reason:field);
    }
    expect(()=>SaleLifecycle.admitted(admission).rejectPayment(),throwsStateError);
  });
}
