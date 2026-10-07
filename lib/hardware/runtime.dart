import 'command_journal.dart';
import 'contracts.dart';
import 'datecs_gateway_adapter.dart';

/// ERP/POS command handlers must use this facade, never call adapter writes
/// directly. Device identity is assigned locally during pairing/configuration.
class HardwareRuntime {
  HardwareRuntime(this.journal);
  final CommandJournal journal;

  Future<HardwareResult> fiscalReceipt(
    String deviceId,
    FiscalDeviceAdapter adapter,
    FiscalReceipt receipt,
  ) => journal.execute(
    id: receipt.commandId,
    deviceId: deviceId,
    operation: 'fiscalReceipt',
    payload: {'vendor': adapter.vendor, 'receipt': receipt.toJson()},
    dispatch: () => adapter.printReceipt(receipt),
  );

  Future<HardwareResult> payment(
    String deviceId,
    PaymentTerminalAdapter adapter,
    PaymentRequest request, {
    Map<String, Object?> binding = const {},
    Future<void> Function()? preflight,
    bool recoveryOnly = false,
  }) async {
    final payload = <String, Object?>{
      'vendor': adapter.vendor,
      'amountMinor': request.amountMinor,
      'currency': request.currency,
      ...binding,
    };
    final existing = await journal.lookup(
      id: request.commandId,
      deviceId: deviceId,
      operation: 'payment',
      payload: payload,
    );
    if (existing != null) return existing;
    if (recoveryOnly) {
      return const HardwareResult(CommandOutcome.unknown,
        message: 'Rezultatul plății nu există în jurnal. Recuperarea nu inițiază o plată nouă.');
    }
    // Reject authorization before recording an in-flight hardware operation.
    // A rejected proof is not a payment with an unknown bank result.
    await preflight?.call();
    return journal.execute(
      id: request.commandId,
      deviceId: deviceId,
      operation: 'payment',
      payload: payload,
      dispatch: () => adapter.pay(request),
    );
  }

  Future<HardwareResult> nonFiscal(
    String deviceId,
    DatecsGatewayAdapter adapter,
    String commandId,
    List<String> lines, {
    Future<HardwareResult?> Function()? preflight,
  }) => journal.execute(
    id: commandId,
    deviceId: deviceId,
    operation: 'nonFiscal',
    payload: {'lines': lines},
    dispatch: () async {
      final blocked = await preflight?.call();
      return blocked ?? await adapter.printNonFiscal(lines);
    },
  );
}
