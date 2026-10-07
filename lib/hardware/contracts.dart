import 'money.dart';

enum CommandOutcome { succeeded, rejected, unknown }

enum FiscalPaymentMethod { cash, card, loyalty }
class ReceiptPayment {
  ReceiptPayment({required this.method,required this.amountMinor}){if(amountMinor<=0||amountMinor>99999999)throw ArgumentError('Invalid receipt tender');}
  final FiscalPaymentMethod method;
  final int amountMinor;
  Map<String,Object> toJson()=>{'method':method.name,'amountMinor':amountMinor};
}

abstract interface class FiscalDeviceAdapter {
  String get vendor;
  Future<DeviceStatus> readStatus();
  Future<HardwareResult> printReceipt(FiscalReceipt receipt);
}

abstract interface class PaymentTerminalAdapter {
  String get vendor;
  Future<HardwareResult> pay(PaymentRequest request);
  Future<HardwareResult> reconcile(PaymentRequest request);
}

class DeviceStatus {
  const DeviceStatus({required this.ready, required this.description, this.details = const {}});
  final bool ready;
  final String description;
  final Map<String, Object?> details;
}

class HardwareResult {
  const HardwareResult(this.outcome, {this.reference, required this.message,this.fiscalIdentity=const {}});
  final CommandOutcome outcome;
  final String? reference;
  final String message;
  final Map<String,String> fiscalIdentity;
}

class PaymentRequest {
  PaymentRequest({
    required this.commandId,
    required this.amountMinor,
    required this.currency,
  }) {
    if (commandId.trim().isEmpty ||
        amountMinor <= 0 ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      throw ArgumentError('Invalid payment identity, amount or currency');
    }
  }
  final String commandId;
  final int amountMinor;
  final String currency;
}

class CashMovementRequest {
  CashMovementRequest({required this.commandId,required this.amountMinor,required this.withdrawal,required this.reason}) {
    if(commandId.isEmpty || amountMinor<=0 || amountMinor>99999999 || reason.trim().isEmpty || reason.length>30 || RegExp(r'[;@\r\n\x00-\x1f]').hasMatch(reason)) {
      throw ArgumentError('Invalid cash movement');
    }
  }
  final String commandId;
  final int amountMinor;
  final bool withdrawal;
  final String reason;
}

class FiscalReceipt {
  FiscalReceipt({
    required this.commandId,
    required this.currency,
    required List<FiscalLine> lines,
    required this.totalMinor,
    required this.paymentMethod,
    this.confirmedPaymentReference,
    this.cui,
    this.claimToken,
    this.documentMode='fiscal',
    List<ReceiptPayment>? payments,
  }) : lines = List.unmodifiable(lines),payments=List.unmodifiable(payments??[ReceiptPayment(method:paymentMethod,amountMinor:totalMinor)]) {
    if (commandId.trim().isEmpty ||
        currency != 'RON' ||
        lines.isEmpty ||
        totalMinor <= 0 ||
        totalMinor > 99999999 || !['fiscal','nonfiscal'].contains(documentMode) || this.payments.isEmpty || this.payments.fold<int>(0,(sum,p)=>sum+p.amountMinor)!=totalMinor || this.payments.map((p)=>p.method).toSet().length!=this.payments.length ||
        (claimToken != null && !RegExp(r'^[A-Za-z0-9]{12}$').hasMatch(claimToken!)) ||
        (cui != null && !RegExp(r'^(RO)?[1-9][0-9]{1,9}$').hasMatch(cui!)) ||
        (paymentMethod == FiscalPaymentMethod.card &&
            (confirmedPaymentReference?.trim().isEmpty ?? true)) ||
        lines.fold<int>(0, (sum, line) => sum + line.grossTotalMinor) !=
            totalMinor) {
      throw ArgumentError(
        'Invalid Romanian fiscal receipt or inconsistent total',
      );
    }
  }
  final String commandId;
  final String currency;
  final List<FiscalLine> lines;
  final int totalMinor;
  final FiscalPaymentMethod paymentMethod;
  final String? confirmedPaymentReference;
  final String? cui;
  final String? claimToken;
  final String documentMode;
  final List<ReceiptPayment> payments;
  Map<String, Object?> toJson() => {
    'commandId': commandId,
    'currency': currency,
    'totalMinor': totalMinor,
    'paymentMethod': paymentMethod.name,
    'confirmedPaymentReference': confirmedPaymentReference,
    if(cui!=null) 'cui':cui,
    if(claimToken!=null) 'claimToken':claimToken,
    'documentMode':documentMode,
    'payments':payments.map((p)=>p.toJson()).toList(),
    'lines': lines.map((line) => line.toJson()).toList(),
  };
}

class FiscalLine {
  FiscalLine({
    required this.name,
    required this.quantityDecimal,
    required this.grossTotalMinor,
    required this.vatGroup,
    required this.unitPriceMinor,
  }) {
    if (name.trim().isEmpty ||
        vatGroup.trim().isEmpty ||
        grossTotalMinor < 0 ||
        unitPriceMinor < 0 ||
        unitPriceMinor > 99999999 ||
        grossTotalMinor != lineTotalMinor(unitPriceMinor, quantityDecimal) ||
        !RegExp(r'^\d+(\.\d+)?$').hasMatch(quantityDecimal) ||
        !RegExp(r'[1-9]').hasMatch(quantityDecimal)) {
      throw ArgumentError('Invalid fiscal line');
    }
  }
  final String name;
  // Decimal text avoids losing precision before conversion to the device SDK.
  final String quantityDecimal;
  final int grossTotalMinor;
  final String vatGroup;
  final int unitPriceMinor;
  Map<String, Object> toJson() => {
    'name': name,
    'quantity': quantityDecimal,
    'unitPriceMinor': unitPriceMinor,
    'grossTotalMinor': grossTotalMinor,
    'vatGroup': vatGroup,
  };
}
