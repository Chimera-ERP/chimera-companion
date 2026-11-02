import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:chimera_companion/main.dart';
import 'package:chimera_companion/printing/niimbot_ble.dart';
import 'package:chimera_companion/printing/niimbot_protocol.dart';
import 'package:chimera_companion/printing/printer_settings_page.dart';

class Discovery extends NiimbotDiscovery {
  int selections = 0;
  @override
  Future<void> scan() async {
    devices['AA:BB:CC:DD:EE:FF'] = DiscoveredDevice(
      id: 'AA:BB:CC:DD:EE:FF',
      name: 'B1_TEST',
      serviceData: const {},
      manufacturerData: Uint8List(0),
      rssi: -50,
      serviceUuids: const [],
    );
    notifyListeners();
  }

  @override
  Future<void> select(String id) async {
    selections++;
    selectedId = id;
    model = NiimbotModel.fromId(4096);
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('packages/forui/Inter')..addFont(rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'))).load();
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets('BLE wizard selects and saves without printing at $size', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final discovery = Discovery();
      addTearDown(discovery.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: key, child: const CompanionApp()),
      );
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('Configurare'))).push(
        MaterialPageRoute<void>(
          builder: (_) => PrinterSettingsPage(discovery: discovery),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bluetooth'));
      await tester.pumpAndSettle();
      expect(find.text('Adresă IPv4 LAN'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continuă'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Caută imprimante'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('B1_TEST'));
      await tester.tap(find.text('B1_TEST'));
      await tester.pumpAndSettle();
      expect(discovery.selections, 1);
      if (const bool.fromEnvironment('CAPTURE_SETUP_UI')) {
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('.quality-receipts').create(recursive: true);
          await File(
            '.quality-receipts/niimbot-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.ensureVisible(find.text('Continuă'));
      await tester.tap(find.text('Continuă'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Salvează'));
      await tester.tap(find.text('Salvează'));
      await tester.pumpAndSettle();
      final config = jsonDecode(
        (await const FlutterSecureStorage().read(
          key: 'production_printer_v1',
        ))!,
      );
      expect(config['protocol'], 'niimbot');
      expect(config['host'], 'ble:AA:BB:CC:DD:EE:FF');
      expect(config['port'], 0);
      expect(config['modelId'], 4096);
      expect(config['widthDots'], 384);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
