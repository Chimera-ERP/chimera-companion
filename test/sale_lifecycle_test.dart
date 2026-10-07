import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/security/sale_lifecycle.dart';

void main() {
  SaleLifecycle admitted()=>SaleLifecycle.admitted({'saleId':'sale','receiptHash':'a'*64,'amountMinor':500,'currency':'RON'});
  test('new admission negotiation initializes versioned state without migrating old clients',(){
    final input={'saleId':'sale','receiptHash':'a'*64,'amountMinor':500,'currency':'RON'};
    expect(SaleLifecycle.issue(input),input);
    expect(input.containsKey('phase'),isFalse);
    expect(SaleLifecycle.issue(input,requestedVersion:1),containsPair('phase','admitted'));
    for(final version in [0,2,'1',true]) {
      expect(()=>SaleLifecycle.issue(input,requestedVersion:version),throwsFormatException);
    }
  });
  test('unpaid cancellation persists a tombstone and cannot start payment after restart',(){
    final cancelled=SaleLifecycle.restore(admitted().abandon().toJson());
    expect(cancelled.abandoned,isTrue);
    expect(cancelled.abandon().toJson(),cancelled.toJson());
    expect(()=>cancelled.beginPayment(commandId:'pay',companion:'terminal',amountMinor:500,currency:'RON'),throwsStateError);
  });
  test('payment start persists binding and identical retries do not create another payment',(){
    final started=admitted().beginPayment(commandId:'pay',companion:'terminal',amountMinor:500,currency:'RON');
    final restarted=SaleLifecycle.restore(started.toJson());
    expect(restarted.beginPayment(commandId:'pay',companion:'terminal',amountMinor:500,currency:'RON').toJson(),started.toJson());
    expect(()=>restarted.abandon(),throwsStateError);
    expect(()=>restarted.beginPayment(commandId:'different',companion:'terminal',amountMinor:500,currency:'RON'),throwsStateError);
    expect(()=>restarted.beginPayment(commandId:'pay',companion:'foreign-terminal',amountMinor:500,currency:'RON'),throwsStateError);
  });
  test('changed amount/currency cannot reuse the admitted identity',(){
    expect(()=>admitted().beginPayment(commandId:'pay',companion:'terminal',amountMinor:501,currency:'RON'),throwsFormatException);
    expect(()=>admitted().beginPayment(commandId:'pay',companion:'terminal',amountMinor:500,currency:'EUR'),throwsFormatException);
  });
  test('external confirmation remains distinct from bank proof and blocks another charge or cancellation',(){
    final confirmed=SaleLifecycle.restore(admitted().confirmExternal(amountMinor:500,currency:'RON').toJson());
    expect(confirmed.toJson()['paymentSource'],'operator_confirmed');
    expect(confirmed.confirmExternal(amountMinor:500,currency:'RON').toJson(),confirmed.toJson());
    expect(()=>confirmed.abandon(),throwsStateError);
    expect(()=>confirmed.beginPayment(commandId:'pay',companion:'terminal',amountMinor:500,currency:'RON'),throwsStateError);
    expect(()=>admitted().beginPayment(commandId:'pay',companion:'terminal',amountMinor:500,currency:'RON').confirmExternal(amountMinor:500,currency:'RON'),throwsStateError);
    expect(()=>admitted().confirmExternal(amountMinor:501,currency:'RON'),throwsFormatException);
  });
  test('corrupted persisted transitions fail closed instead of resetting to unpaid',(){
    expect(()=>SaleLifecycle.restore({...admitted().toJson(),'phase':'payment_started'}),throwsFormatException);
    expect(()=>SaleLifecycle.restore({...admitted().toJson(),'phase':'unknown'}),throwsFormatException);
    expect(()=>SaleLifecycle.restore({...admitted().toJson(),'lifecycleVersion':2}),throwsFormatException);
    expect(()=>SaleLifecycle.restore({...admitted().toJson(),'paymentCommandId':'pay'}),throwsFormatException);
  });
  test('receipt cannot bypass persisted external confirmation or integrated payment binding',(){
    expect(()=>admitted().requireReceiptState(paymentMethod:'cash',external:false),returnsNormally);
    expect(()=>admitted().requireReceiptState(paymentMethod:'card',external:true),throwsStateError);
    expect(()=>admitted().requireReceiptState(paymentMethod:'card',external:false,paymentCommandId:'pay'),throwsStateError);
    final external=SaleLifecycle.restore(admitted().confirmExternal(amountMinor:500,currency:'RON').toJson());
    expect(()=>external.requireReceiptState(paymentMethod:'card',external:true),returnsNormally);
    expect(()=>external.requireReceiptState(paymentMethod:'card',external:false,paymentCommandId:'pay'),throwsStateError);
    expect(()=>external.requireReceiptState(paymentMethod:'cash',external:false),throwsStateError);
    final integrated=SaleLifecycle.restore(admitted().beginPayment(commandId:'pay',companion:'terminal',amountMinor:500,currency:'RON').toJson());
    expect(()=>integrated.requireReceiptState(paymentMethod:'card',external:false,paymentCommandId:'pay'),returnsNormally);
    expect(()=>integrated.requireReceiptState(paymentMethod:'card',external:false,paymentCommandId:'another'),throwsStateError);
    expect(()=>integrated.requireReceiptState(paymentMethod:'card',external:true),throwsStateError);
    expect(()=>admitted().abandon().requireReceiptState(paymentMethod:'cash',external:false),throwsStateError);
  });
}
