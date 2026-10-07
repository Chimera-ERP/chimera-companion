/// Vendor-neutral persisted lifecycle. The caller verifies signed actor/peer
/// identity before transitions and persists a transition before dispatch.
/// This is not payment evidence and never turns a timeout into cancellation.
class SaleLifecycle {
  SaleLifecycle._(this._value);
  final Map<String,dynamic> _value;

  /// Negotiate only new admissions. Persisted admissions are returned unchanged
  /// by the bridge; a software upgrade must not reinterpret an old payment.
  static Map<String,dynamic> issue(Map<String,dynamic> admission,{Object? requestedVersion}) {
    if(requestedVersion==null)return Map<String,dynamic>.from(admission);
    if(requestedVersion is! int||requestedVersion!=1)throw const FormatException('Unsupported requested sale lifecycle');
    return SaleLifecycle.admitted(admission).toJson();
  }

  factory SaleLifecycle.admitted(Map<String,dynamic> admission) {
    if(admission['saleId'] is! String||(admission['saleId'] as String).isEmpty||
      admission['receiptHash'] is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(admission['receiptHash'])||
      admission['amountMinor'] is! int||admission['amountMinor']<=0||admission['amountMinor']>99999999||admission['currency']!='RON') {
      throw const FormatException('Invalid sale lifecycle identity');
    }
    return SaleLifecycle._({...admission,'lifecycleVersion':1,'phase':'admitted'});
  }

  factory SaleLifecycle.restore(Map<String,dynamic> stored) {
    final checked=SaleLifecycle.admitted(stored);
    if(stored['lifecycleVersion']!=1||!['admitted','payment_started','external_confirmed','abandoned'].contains(stored['phase'])) {
      throw const FormatException('Unsupported sale lifecycle');
    }
    if(stored['phase']=='payment_started' &&
      (stored['paymentCommandId'] is! String||(stored['paymentCommandId'] as String).isEmpty||
       stored['paymentCompanion'] is! String||(stored['paymentCompanion'] as String).isEmpty)) {
      throw const FormatException('Missing persisted payment identity');
    }
    if(stored['phase']!='payment_started'&&(stored.containsKey('paymentCommandId')||stored.containsKey('paymentCompanion'))) {
      throw const FormatException('Ambiguous persisted payment state');
    }
    if((stored['phase']=='external_confirmed')!=(stored['paymentSource']=='operator_confirmed')||
      (stored['phase']!='external_confirmed'&&stored.containsKey('paymentSource'))) {
      throw const FormatException('Ambiguous external payment state');
    }
    return SaleLifecycle._({...checked._value,...stored});
  }

  Map<String,dynamic> toJson()=>Map<String,dynamic>.from(_value);
  bool get abandoned=>_value['phase']=='abandoned';

  /// Checks persisted intent before a new hardware dispatch. Signature and bank
  /// evidence verification remain the caller's responsibility.
  void requireReceiptState({required String paymentMethod,required bool external,
    String? paymentCommandId}) {
    if(abandoned)throw StateError('Sale was abandoned');
    if(paymentMethod=='cash'||paymentMethod=='loyalty') {
      if(_value['phase']!='admitted'||external||paymentCommandId!=null) {
        throw StateError('Cash receipt conflicts with persisted payment');
      }
      return;
    }
    if(paymentMethod!='card')throw const FormatException('Unsupported receipt payment');
    if(external) {
      if(_value['phase']!='external_confirmed'||paymentCommandId!=null) {
        throw StateError('External payment must be confirmed before receipt');
      }
    } else if(_value['phase']!='payment_started'||paymentCommandId!=_value['paymentCommandId']) {
      throw StateError('Receipt does not match the admitted integrated payment');
    }
  }

  SaleLifecycle beginPayment({required String commandId,required String companion,
    required int amountMinor,required String currency}) {
    if(commandId.isEmpty||companion.isEmpty||amountMinor!=_value['amountMinor']||currency!=_value['currency']) {
      throw const FormatException('Payment does not match admitted sale');
    }
    if(abandoned)throw StateError('Sale was abandoned');
    if(_value['phase']=='external_confirmed')throw StateError('External payment already confirmed; do not collect again');
    if(_value['phase']=='payment_started') {
      if(_value['paymentCommandId']!=commandId||_value['paymentCompanion']!=companion)throw StateError('Another payment is already admitted');
      return this;
    }
    return SaleLifecycle._({..._value,'phase':'payment_started','paymentCommandId':commandId,'paymentCompanion':companion});
  }

  SaleLifecycle confirmExternal({required int amountMinor,required String currency}) {
    if(amountMinor!=_value['amountMinor']||currency!=_value['currency'])throw const FormatException('External confirmation does not match sale');
    if(abandoned||_value['phase']=='payment_started')throw StateError('External confirmation cannot replace another payment');
    return SaleLifecycle._({..._value,'phase':'external_confirmed','paymentSource':'operator_confirmed'});
  }

  SaleLifecycle abandon() {
    if(_value['phase']=='payment_started'||_value['phase']=='external_confirmed')throw StateError('Payment may have started; recover its result');
    return SaleLifecycle._({..._value,'phase':'abandoned'});
  }

  /// Call only after verifying the terminal's signed, persisted rejection.
  SaleLifecycle rejectPayment() {
    if(_value['phase']!='payment_started')throw StateError('No admitted integrated payment');
    return SaleLifecycle._({..._value,'phase':'abandoned'}..remove('paymentCommandId')..remove('paymentCompanion'));
  }
}
