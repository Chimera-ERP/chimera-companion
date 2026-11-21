import 'dart:io';
import 'contracts.dart';

enum FiscalModel { tremolM20, tremolFp21, datecsDp25 }

sealed class FiscalEndpoint {
  const FiscalEndpoint();

  factory FiscalEndpoint.fromSettings(Map<String, dynamic> data) {
    final transport = data['transport'] ?? 'lan';
    if (transport == 'lan') {
      return LanEndpoint(host: data['host'] as String, port: int.parse('${data['port']}'));
    }
    return FiscalSerialEndpoint(
      transport: transport as String,
      deviceId: data['deviceId'] as String,
      baudRate: int.parse('${data['baudRate'] ?? 115200}'),
      model: FiscalModel.values.byName(data['model'] as String),
    );
  }

  String get key;
  String get label;
}

class FiscalSerialEndpoint extends FiscalEndpoint {
  FiscalSerialEndpoint({required this.transport, required this.deviceId, this.baudRate = 115200, this.model}) {
    final valid = switch (transport) {
      'bluetooth' => RegExp(r'^(?:[A-F0-9]{2}:){5}[A-F0-9]{2}$').hasMatch(deviceId),
      'usb' => RegExp(r'^[a-f0-9]{64}$').hasMatch(deviceId),
      _ => false,
    };
    if (!valid || ![9600, 19200, 38400, 57600, 115200].contains(baudRate)) {
      throw ArgumentError('Identitate sau viteză serială invalidă.');
    }
  }

  final String transport;
  final String deviceId;
  final int baudRate;
  final FiscalModel? model;
  @override
  String get key => '$transport:$deviceId';
  @override
  String get label => transport == 'usb' ? 'USB · ${deviceId.substring(0, 12)}' : 'Bluetooth · $deviceId';
}

class LanEndpoint extends FiscalEndpoint {
  LanEndpoint({required this.host, required this.port}) {
    final ip = InternetAddress.tryParse(host);
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        port < 1 ||
        port > 65535) {
      throw ArgumentError(
        'An explicit local IPv4 address and port are required',
      );
    }
    final b = ip.rawAddress;
    if (!(b[0] == 10 ||
        b[0] == 127 ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31))) {
      throw ArgumentError('Hardware endpoints must be on a private LAN');
    }
  }
  final String host;
  final int port;
  @override
  String get key => '$host:$port';
  @override
  String get label => key;
  Map<String, Object> toJson() => {'host': host, 'port': port};
}

class FiscalConnection {
  FiscalConnection({
    required this.id,
    required this.model,
    required FiscalEndpoint endpoint,
    required this.operatorNumber,
    required this.operatorPassword,
    required this.cashPaymentCode,
    required this.cardPaymentCode,
    this.tillNumber = '1',
    this.tcpPassword = '',
    this.loyaltyPaymentCode,
    bool allowUnknownOperatorPassword = false,
  }) : target = endpoint {
    if (id.trim().isEmpty ||
        operatorNumber < 1 ||
        operatorNumber > (model == FiscalModel.datecsDp25 ? 30 : 20) ||
        (!(allowUnknownOperatorPassword && operatorPassword.isEmpty) &&
            !RegExp(
              model == FiscalModel.datecsDp25
                  ? r'^\d{1,8}$'
                  : r'^[\x20-\x3a\x3c-\x7e]{4}$',
            ).hasMatch(operatorPassword)) ||
        !RegExp(r'^\d{1,5}$').hasMatch(tillNumber)) {
      throw ArgumentError('Invalid fiscal operator configuration');
    }
    if (tcpPassword.length > 20 ||
        tcpPassword.codeUnits.any((b) => b < 32 || b > 126)) {
      throw ArgumentError('Invalid TCP password');
    }
    final paymentPattern = model == FiscalModel.datecsDp25
        ? r'^[0-5PNCDIJKL]$'
        : r'^\d$';
    if (!RegExp(paymentPattern).hasMatch(cashPaymentCode) ||
        !RegExp(paymentPattern).hasMatch(cardPaymentCode) ||
        cashPaymentCode == cardPaymentCode ||
        (loyaltyPaymentCode != null && (!RegExp(paymentPattern).hasMatch(loyaltyPaymentCode!) || loyaltyPaymentCode == cashPaymentCode || loyaltyPaymentCode == cardPaymentCode))) {
      throw ArgumentError('Configure distinct cash and card payment codes');
    }
  }
  final String id;
  final FiscalModel model;
  final FiscalEndpoint target;
  /// Only for the legacy network-only Datecs SDK and LAN callers.
  LanEndpoint get endpoint => target as LanEndpoint;
  final int operatorNumber;
  final String operatorPassword;
  final String cashPaymentCode;
  final String cardPaymentCode;
  final String tillNumber;
  final String tcpPassword;
  final String? loyaltyPaymentCode;
  String paymentCode(FiscalPaymentMethod method)=>switch(method){FiscalPaymentMethod.cash=>cashPaymentCode,FiscalPaymentMethod.card=>cardPaymentCode,FiscalPaymentMethod.loyalty=>loyaltyPaymentCode??(throw ArgumentError('Configurează metoda ECR pentru coins în ERP.'))};
}
