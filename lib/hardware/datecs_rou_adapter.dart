import 'package:flutter/services.dart';
import 'connection.dart';
import 'contracts.dart';
import 'text_encoding.dart';

class DatecsRouAdapter implements FiscalDeviceAdapter {
  DatecsRouAdapter(this.connection, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('chimera/hardware/datecs_rou') {
    if (connection.model != FiscalModel.datecsDp25) {
      throw ArgumentError('Not a Datecs model');
    }
  }
  final FiscalConnection connection;
  final MethodChannel _channel;
  static Future<List<Map<String, dynamic>>> networkInfo() async {
    final response = await const MethodChannel(
      'chimera/hardware/datecs_rou',
    ).invokeListMethod<Object?>('networkInfo');
    return (response ?? [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> discover({
    MethodChannel? channel,
  }) async {
    final response =
        await (channel ?? const MethodChannel('chimera/hardware/datecs_rou'))
            .invokeListMethod<Object?>('discover');
    return (response ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  @override
  String get vendor => 'datecs';
  static Future<Map<String, Object?>?> _invoke(
    FiscalEndpoint endpoint,
    String method,
    MethodChannel? channel, [
    Map<String, Object?>? payload,
  ]) {
    if (endpoint is LanEndpoint) {
      final native =
          channel ?? const MethodChannel('chimera/hardware/datecs_rou');
      return native.invokeMapMethod<String, Object?>(method, {
        ...endpoint.toJson(),
        ...?payload,
      });
    }
    final target = endpoint as FiscalSerialEndpoint;
    return const MethodChannel(
      'chimera/fiscal-serial',
    ).invokeMapMethod<String, Object?>('legacyOperation', {
      'id': target.deviceId,
      'transport': target.transport,
      'baudRate': target.baudRate,
      'operation': method,
      ...?payload,
    });
  }

  Future<Map<String, double>> readVatRates() async {
    final result = await _invoke(connection.target, 'readVatRates', _channel);
    final enabled = result?['enabled'];
    final rates = result?['rates'];
    if (enabled is! String ||
        !RegExp(r'^[01]{4}$').hasMatch(enabled) ||
        rates is! List ||
        rates.length != enabled.length ||
        result?['decimals'] != '2') {
      throw const FormatException('Invalid Datecs ROU VAT configuration');
    }
    final groups = <String, double>{};
    for (var i = 0; i < enabled.length; i++) {
      if (enabled[i] == '0') continue;
      final rate = rates[i];
      if (rate is! String || !RegExp(r'^\d{1,2}(\.\d{1,2})?$').hasMatch(rate)) {
        throw const FormatException('Invalid active Datecs ROU VAT rate');
      }
      groups[String.fromCharCode(65 + i)] = double.parse(rate);
    }
    return groups;
  }

  @override
  Future<DeviceStatus> readStatus() async {
    return readEndpointStatus(connection.target, channel: _channel);
  }

  static Future<DeviceStatus> readEndpointStatus(
    FiscalEndpoint endpoint, {
    MethodChannel? channel,
  }) async {
    final response = await probeEndpoint(endpoint, channel: channel);
    return DeviceStatus(
      ready: response['ready'] == true,
      description: response['description'] as String? ?? 'Datecs indisponibil',
    );
  }

  static Future<Map<String, Object?>> probeEndpoint(
    FiscalEndpoint endpoint, {
    MethodChannel? channel,
  }) async {
    final response = await _invoke(endpoint, 'status', channel);
    return response ?? {};
  }

  static Future<HardwareResult> printXReport(
    FiscalEndpoint endpoint, {
    MethodChannel? channel,
  }) => printReport(endpoint, closeDay: false, channel: channel);

  static Future<HardwareResult> printReport(
    FiscalEndpoint endpoint, {
    required bool closeDay,
    MethodChannel? channel,
  }) async {
    try {
      final response = await _invoke(
        endpoint,
        closeDay ? 'zReport' : 'xReport',
        channel,
      );
      return HardwareResult(
        switch (response?['outcome']) {
          'succeeded' => CommandOutcome.succeeded,
          'rejected' => CommandOutcome.rejected,
          _ => CommandOutcome.unknown,
        },
        message:
            response?['message'] as String? ??
            'Rezultat raport X incert. Verifică ECR-ul.',
      );
    } on MissingPluginException {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Raport X Datecs disponibil pe Android.',
      );
    } catch (_) {
      return const HardwareResult(
        CommandOutcome.unknown,
        message: 'Conexiune pierdută. Verifică dacă raportul X s-a tipărit.',
      );
    }
  }

  void validateReceipt(FiscalReceiptDraft receipt) {
    if (receipt.claimToken != null || receipt.cui != null) {
      throw ArgumentError(
        'Datecs nu acceptă CUI sau cod de fidelitate pe acest bon fiscal.',
      );
    }
    if (receipt.payments.length != 1 ||
        receipt.paymentMethod != receipt.payments.single.method ||
        receipt.paymentMethod == FiscalPaymentMethod.loyalty) {
      throw ArgumentError(
        'Plățile compuse nu sunt validate pentru acest profil Datecs.',
      );
    }
    if (connection.operatorNumber > 16 ||
        !RegExp(r'^\d{4,8}$').hasMatch(connection.operatorPassword) ||
        !RegExp(
          r'^[PNCDIJKL]$',
        ).hasMatch(connection.paymentCode(receipt.paymentMethod))) {
      throw ArgumentError(
        'Invalid Datecs ROU operator or tender configuration',
      );
    }
    for (final line in receipt.lines) {
      encodeFiscalText(line.name, maxBytes: 30);
      if (!RegExp(r'^[A-G]$').hasMatch(line.vatGroup) ||
          line.name.contains('\t')) {
        throw ArgumentError('Unsupported Datecs fiscal line');
      }
    }
  }

  @override
  Future<HardwareResult> printReceipt(FiscalReceipt receipt) async {
    validateReceipt(receipt);
    try {
      final response = await _invoke(connection.target, 'receipt', _channel, {
        'operatorNumber': connection.operatorNumber,
        'operatorPassword': connection.operatorPassword,
        'tillNumber': connection.tillNumber,
        'cashPaymentCode': connection.cashPaymentCode,
        'cardPaymentCode': connection.cardPaymentCode,
        'receipt': receipt.toJson(),
      });
      final outcome = switch (response?['outcome']) {
        'succeeded' => CommandOutcome.succeeded,
        'rejected' => CommandOutcome.rejected,
        _ => CommandOutcome.unknown,
      };
      final reference = response?['reference'] as String?;
      return HardwareResult(
        outcome == CommandOutcome.succeeded && (reference?.isEmpty ?? true)
            ? CommandOutcome.unknown
            : outcome,
        reference: reference,
        message: response?['message'] as String? ?? 'Rezultat incert Datecs',
      );
    } on MissingPluginException {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Adaptor Datecs România disponibil momentan numai pe Android',
      );
    } catch (_) {
      return const HardwareResult(
        CommandOutcome.unknown,
        message: 'Nu retrimite; verifică bonul pe Datecs',
      );
    }
  }
}
