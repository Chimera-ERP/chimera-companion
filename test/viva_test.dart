import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/json_transport.dart';
import 'package:chimera_companion/hardware/viva_adapter.dart';

const session = '83b3c7d4-244b-4b27-8c26-a0e773e2c230';
PaymentRequest payment() =>
    PaymentRequest(commandId: session, amountMinor: 2000, currency: 'RON');
Map<String, Object?> response(
  String state, {
  int amount = 2000,
  int event = 0,
}) => {
  'state': state,
  'sessionType': 'SALE',
  'sessionId': session,
  if (state != 'PROCESSING')
    'payloadData': {
      'saleResponse': {
        'transactionEventId': event,
        'transactionId': 'payment-confirmed',
        'amount': amount,
        'merchantReference': session,
      },
    },
};

class VivaPeer implements JsonTransport {
  VivaPeer(this.responses);
  final List<Map<String, Object?>> responses;
  final List<(String, String, Map<String, Object?>?)> calls = [];
  bool fail = false;
  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    calls.add((method, path, body));
    if (fail) throw StateError('Lost reply');
    return responses.removeAt(0);
  }
}

void main() {
  test(
    '20 RON stays 2000 bani; PROCESSING is polled, never counted as paid',
    () async {
      final peer = VivaPeer([response('PROCESSING'), response('SUCCESS')]);
      final result = await VivaAdapter(peer, wait: () async {}).pay(payment());
      expect(result.outcome, CommandOutcome.succeeded);
      expect(peer.calls.first.$3!['amount'], 2000);
      expect(peer.calls.first.$3!['currencyCode'], 946);
      expect(peer.calls.first.$3!['showReceipt'], false);
      expect(peer.calls.first.$3!['showTransactionResult'], true);
      expect(peer.calls.map((call) => call.$1), ['POST', 'GET']);
    },
  );
  test('declined terminal transaction remains rejected', () async {
    final peer = VivaPeer([response('FAILURE', event: 1004)]);
    expect(
      (await VivaAdapter(peer).pay(payment())).outcome,
      CommandOutcome.rejected,
    );
  });
  test('lost reply never causes second payment request', () async {
    final peer = VivaPeer([])..fail = true;
    expect(
      (await VivaAdapter(peer).pay(payment())).outcome,
      CommandOutcome.unknown,
    );
    expect(peer.calls.length, 1);
  });
  test('wrong amount or session cannot confirm payment', () async {
    final peer = VivaPeer([response('SUCCESS', amount: 1736)]);
    expect(
      (await VivaAdapter(peer).pay(payment())).outcome,
      CommandOutcome.unknown,
    );
    final other = response('SUCCESS')..['sessionId'] = 'different';
    expect(
      (await VivaAdapter(VivaPeer([other])).pay(payment())).outcome,
      CommandOutcome.unknown,
    );
  });
  test('reconciliation is GET-only and checks original amount', () async {
    final peer = VivaPeer([response('SUCCESS', amount: 2001)]);
    expect(
      (await VivaAdapter(peer).reconcile(payment())).outcome,
      CommandOutcome.unknown,
    );
    expect(peer.calls.single.$1, 'GET');
  });
  test('unfinished session stays unknown after bounded polling', () async {
    final peer = VivaPeer([response('PROCESSING'), response('PROCESSING')]);
    expect(
      (await VivaAdapter(
        peer,
        pollAttempts: 1,
        wait: () async {},
      ).pay(payment())).outcome,
      CommandOutcome.unknown,
    );
    expect(peer.calls.where((call) => call.$1 == 'POST').length, 1);
  });
}
