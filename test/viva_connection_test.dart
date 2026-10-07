import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/device_setup.dart';
import 'package:chimera_companion/hardware/viva_connection.dart';

void main() {
  test(
    'Viva defaults to same-device loopback and port 9564; manual LAN remains supported',
    () {
      expect(vivaEndpoint('', '').host, '127.0.0.1');
      expect(vivaEndpoint('localhost', '').port, 9564);
      expect(vivaEndpoint('192.168.1.50', '9565').host, '192.168.1.50');
      expect(vivaEndpoint('192.168.1.50', '9565').port, 9565);
      expect(() => vivaEndpoint('8.8.8.8', '9564'), throwsArgumentError);
      expect(() => vivaEndpoint('127.0.0.1', '0'), throwsArgumentError);
    },
  );
  test(
    'unreachable Viva is reported as unavailable, not a successful connection',
    () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final endpoint = vivaEndpoint('localhost', '${socket.port}');
      await socket.close();
      final result = await checkVivaConnection(endpoint, '');
      expect(result.trusted, false);
      expect(result.certificate, isNull);
      expect(result.message, contains('Viva inaccesibil'));
    },
  );
  testWidgets(
    'Viva step exposes local defaults, manual IP and explicit connection test',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        const MaterialApp(home: DeviceSetupPage(initialStep: 3)),
      );
      await tester.pumpAndSettle();
      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(
        fields.any((field) => field.controller?.text == '127.0.0.1'),
        true,
      );
      expect(fields.any((field) => field.controller?.text == '9564'), true);
      expect(find.text('Configurează Viva mai târziu'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(find.text('Continuă la verificare'), findsOneWidget);
      expect(find.text('Verifică Viva · fără plată'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
