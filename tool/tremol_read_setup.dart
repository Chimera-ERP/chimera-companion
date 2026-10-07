import 'dart:convert';
import 'dart:io';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/tremol_adapter.dart';

// Read-only qualification; passwords and raw response bytes are never logged.
Future<void> main(List<String> arguments) async {
  final adapter = TremolAdapter(
    FiscalConnection(
      id: 'setup-read',
      model: FiscalModel.tremolM20,
      endpoint: LanEndpoint(host: arguments[0], port: 8000),
      operatorNumber: 1,
      operatorPassword: '0000',
      cashPaymentCode: '0',
      cardPaymentCode: '1',
      tcpPassword: Platform.environment['TREMOL_LAN_PASSWORD'] ?? '',
    ),
  );
  try {
    final operator = await adapter.readOperatorConfiguration();
    stdout.writeln(
      jsonEncode({
        'operator': operator['name'],
        'passwordLength': operator['password']!.length,
      }),
    );
  } catch (error) {
    stdout.writeln('Operator read: $error');
  }
  try {
    stdout.writeln(jsonEncode({'vatRates': await adapter.readVatRates()}));
  } catch (error) {
    stdout.writeln('VAT read: $error');
  }
}
