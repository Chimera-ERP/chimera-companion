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
  Map<String, Object> get _endpoint => connection.endpoint.toJson();

  @override
  Future<DeviceStatus> readStatus() async {
    return readEndpointStatus(connection.endpoint, channel: _channel);
  }

  static Future<DeviceStatus> readEndpointStatus(
    LanEndpoint endpoint, {
    MethodChannel? channel,
  }) async {
    final response = await probeEndpoint(endpoint, channel: channel);
    return DeviceStatus(
      ready: response['ready'] == true,
      description: response['description'] as String? ?? 'Datecs indisponibil',
    );
  }

  static Future<Map<String, Object?>> probeEndpoint(
    LanEndpoint endpoint, {
    MethodChannel? channel,
  }) async {
    final native =
        channel ?? const MethodChannel('chimera/hardware/datecs_rou');
    final response = await native.invokeMapMethod<String, Object?>(
      'status',
      endpoint.toJson(),
    );
    return response ?? {};
  }

  static Future<HardwareResult> printXReport(
    LanEndpoint endpoint, {
    MethodChannel? channel,
  }) => printReport(endpoint, closeDay: false, channel: channel);

  static Future<HardwareResult> printReport(
    LanEndpoint endpoint, {
    required bool closeDay,
    MethodChannel? channel,
  }) async {
    try {
      final response =
          await (channel ?? const MethodChannel('chimera/hardware/datecs_rou'))
              .invokeMapMethod<String, Object?>(
                closeDay ? 'zReport' : 'xReport',
                endpoint.toJson(),
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

  @override
  Future<HardwareResult> printReceipt(FiscalReceipt receipt) async {
    for (final line in receipt.lines) {
      encodeFiscalText(line.name, maxBytes: 30);
      if (!RegExp(r'^[A-G]$').hasMatch(line.vatGroup) ||
          line.name.contains('\t')) {
        throw ArgumentError('Unsupported Datecs fiscal line');
      }
    }
    try {
      final response = await _channel
          .invokeMapMethod<String, Object?>('receipt', {
            ..._endpoint,
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
