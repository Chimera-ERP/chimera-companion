import 'support/still_widget.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:forui/forui.dart';
import 'package:chimera_companion/printing/printer_settings_page.dart';

void main() {
  testWidgets(
    'optional printer settings load, validate and save at narrow width without hardware I/O',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'erp_pairing_v1': 'identity-unchanged',
        'local_hardware_v1': '{"host":"192.168.1.25"}',
      });
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpStillWidget(
        tester,
        MaterialApp(
          builder: (_, child) =>
              FTheme(data: FTheme.neutral.dark.touch, child: child!),
          home: const PrinterSettingsPage(),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Bluetooth'))
            .enabled,
        true,
      );
      await tester.tap(find.text('LAN'));
      await tester.pumpAndSettle();
      expect(
        await const FlutterSecureStorage().read(key: 'production_printer_v1'),
        isNull,
      );
      final save = find.widgetWithText(FilledButton, 'Continuă');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.textContaining('Adresă IPv4 LAN privată'), findsOneWidget);
      final host = find.widgetWithText(TextField, 'Adresă IPv4 LAN');
      await tester.ensureVisible(host);
      await tester.enterText(host, '192.168.1.30');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(FilledButton, 'Salvează');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      final saved = jsonDecode(
        (await const FlutterSecureStorage().read(
          key: 'production_printer_v1',
        ))!,
      );
      expect(saved['host'], '192.168.1.30');
      expect(saved['protocol'], 'escpos');
      expect(find.textContaining('nu s-a imprimat nimic'), findsOneWidget);
      expect(
        await const FlutterSecureStorage().read(key: 'erp_pairing_v1'),
        'identity-unchanged',
      );
      expect(
        await const FlutterSecureStorage().read(key: 'local_hardware_v1'),
        '{"host":"192.168.1.25"}',
      );
      expect(tester.takeException(), isNull);
      await pumpStillWidget(tester, const SizedBox());
    },
  );
}
