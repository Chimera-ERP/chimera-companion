import 'contracts.dart';
import 'json_transport.dart';

class VivaAdapter implements PaymentTerminalAdapter {
  VivaAdapter(
    this.transport, {
    this.currencyNumbers = const {'RON': '946'},
    this.pollAttempts = 30,
    Future<void> Function()? wait,
  }) : _wait = wait ?? (() => Future<void>.delayed(const Duration(seconds: 1)));
  final JsonTransport transport;
  final Map<String, String> currencyNumbers;
  final int pollAttempts;
  final Future<void> Function() _wait;
  @override
  String get vendor => 'viva_local';
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  HardwareResult _result(Map<String, Object?> value, String sessionId) {
    if (value['sessionId'] != sessionId || value['sessionType'] != 'SALE') {
      return HardwareResult(
        CommandOutcome.unknown,
        reference: sessionId,
        message: 'Răspuns Viva pentru altă sesiune',
      );
    }
    final data = value['payloadData'];
    final sale = data is Map ? data['saleResponse'] : null;
    if (value['state'] == 'SUCCESS' &&
        sale is Map &&
        sale['transactionEventId'] == 0 &&
        sale['transactionId'] is String &&
        (sale['transactionId'] as String).isNotEmpty) {
      return HardwareResult(
        CommandOutcome.succeeded,
        reference: sale['transactionId'] as String,
        message: 'Plată confirmată de Viva',
      );
    }
    if (value['state'] == 'FAILURE' &&
        sale is Map &&
        sale['transactionEventId'] is int &&
        [
          1000,
          1004,
          1006,
          1007,
          1016,
          1020,
        ].contains(sale['transactionEventId'])) {
      return HardwareResult(
        CommandOutcome.rejected,
        reference: sessionId,
        message: 'Plată refuzată sau anulată de Viva',
      );
    }
    return HardwareResult(
      CommandOutcome.unknown,
      reference: sessionId,
      message: 'Plată neconfirmată. Verifică sesiunea; nu iniția altă plată.',
    );
  }

  @override
  Future<HardwareResult> pay(PaymentRequest request) async {
    final currency = currencyNumbers[request.currency];
    if (!_uuid.hasMatch(request.commandId) ||
        currency == null ||
        !RegExp(r'^\d{3}$').hasMatch(currency)) {
      throw ArgumentError(
        'Viva requires UUID session identity and a configured numeric currency',
      );
    }
    try {
      final initial = await transport.request('POST', '/pos/v1/sale', {
        'sessionId': request.commandId,
        'amount': request.amountMinor,
        'merchantReference': request.commandId,
        'currencyCode': int.parse(currency),
        'preauth': false,
        'showReceipt': false,
        'showTransactionResult': true,
        'skipSurcharge': true,
      });
      if (initial['sessionId'] != request.commandId ||
          initial['sessionType'] != 'SALE') {
        return _result(initial, request.commandId);
      }
      var value = initial;
      for (var i = 0; value['state'] == 'PROCESSING' && i < pollAttempts; i++) {
        await _wait();
        value = await transport.request(
          'GET',
          '/pos/v1/sessions/${request.commandId}',
        );
      }
      final result = _result(value, request.commandId);
      final data = value['payloadData'];
      final sale = data is Map ? data['saleResponse'] : null;
      if (result.outcome == CommandOutcome.succeeded &&
          (sale is! Map ||
              sale['amount'] != request.amountMinor ||
              sale['merchantReference'] != request.commandId)) {
        return HardwareResult(
          CommandOutcome.unknown,
          reference: request.commandId,
          message: 'Suma sau referința Viva nu corespunde cererii',
        );
      }
      return result;
    } catch (_) {
      return HardwareResult(
        CommandOutcome.unknown,
        reference: request.commandId,
        message: 'Rezultat Viva incert. Nu retrimite plata; verifică sesiunea.',
      );
    }
  }

  @override
  Future<HardwareResult> reconcile(PaymentRequest request) async {
    final transactionReference = request.commandId;
    if (!_uuid.hasMatch(transactionReference)) {
      throw ArgumentError('Invalid Viva session UUID');
    }
    try {
      final value = await transport.request(
        'GET',
        '/pos/v1/sessions/$transactionReference',
      );
      final result = _result(value, transactionReference);
      final data = value['payloadData'];
      final sale = data is Map ? data['saleResponse'] : null;
      if (result.outcome == CommandOutcome.succeeded &&
          (sale is! Map ||
              sale['amount'] != request.amountMinor ||
              sale['merchantReference'] != request.commandId)) {
        return HardwareResult(
          CommandOutcome.unknown,
          reference: transactionReference,
          message: 'Suma sau referința Viva nu corespunde cererii',
        );
      }
      return result;
    } catch (_) {
      return HardwareResult(
        CommandOutcome.unknown,
        reference: transactionReference,
        message: 'Sesiunea Viva nu poate fi verificată încă',
      );
    }
  }
}
