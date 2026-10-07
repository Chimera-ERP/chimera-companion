import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/tremol_catalog.dart';

void main() {
  test('payments use minor units and reject invalid identities', () {
    expect(
      PaymentRequest(
        commandId: 'cmd-1',
        amountMinor: 2000,
        currency: 'RON',
      ).amountMinor,
      2000,
    );
    expect(
      () => PaymentRequest(commandId: '', amountMinor: 2000, currency: 'RON'),
      throwsArgumentError,
    );
    expect(
      () => PaymentRequest(commandId: 'cmd', amountMinor: 0, currency: 'RON'),
      throwsArgumentError,
    );
  });
  test('receipt totals are validated without float rounding', () {
    final line = FiscalLine(
      name: 'Cafea',
      quantityDecimal: '1',
      grossTotalMinor: 2000,
      unitPriceMinor: 2000,
      vatGroup: 'A',
    );
    expect(
      FiscalReceipt(
        commandId: 'cmd',
        currency: 'RON',
        lines: [line],
        totalMinor: 2000,
        paymentMethod: FiscalPaymentMethod.cash,
      ).totalMinor,
      2000,
    );
    expect(
      () => FiscalReceipt(
        commandId: 'cmd',
        currency: 'RON',
        lines: [line],
        totalMinor: 2001,
        paymentMethod: FiscalPaymentMethod.cash,
      ),
      throwsArgumentError,
    );
    expect(
      () => FiscalLine(
        name: 'Cafea',
        quantityDecimal: '0.00',
        grossTotalMinor: 0,
        unitPriceMinor: 0,
        vatGroup: 'A',
      ),
      throwsArgumentError,
    );
  });
  test(
    'catalog preserves full command definition and rejects malformed data',
    () {
      final items = TremolCatalogClient.parse(
        '[{"Name":"ReadStatus","Doc":"<Command />","FpOperation":"Read state"}]',
      );
      expect(items.single.definition, '<Command />');
      expect(() => TremolCatalogClient.parse('{}'), throwsFormatException);
      expect(
        () => TremolCatalogClient(Uri.parse('http://user:secret@localhost/')),
        throwsArgumentError,
      );
      expect(
        () => TremolCatalogClient(Uri.parse('http://localhost/PaperFeed()')),
        throwsArgumentError,
      );
    },
  );
}
