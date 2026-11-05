import 'support/still_widget.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/main.dart';
import 'package:chimera_companion/printing/printer_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('packages/forui/Inter')
      ..addFont(rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets('profile and printer transport fit $size', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final printer in [false, true]) {
        final key = GlobalKey();
        await pumpStillWidget(
          tester,
          RepaintBoundary(key: key, child: const CompanionApp()),
        );
        await tester.pumpAndSettle();
        if (printer) {
          Navigator.of(tester.element(find.text('Configurare'))).push(
            MaterialPageRoute<void>(
              builder: (_) => const PrinterSettingsPage(),
            ),
          );
          await tester.pumpAndSettle();
        }
        expect(find.text(printer ? 'LAN' : 'PIN de conectare'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('CAPTURE_SETUP_UI')) {
          await tester.runAsync(
            () => precacheImage(
              AssetImage(
                'assets/motion/${printer ? 'printer' : 'welcome'}.png',
              ),
              key.currentContext!,
            ),
          );
          await tester.pump();
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('.quality-receipts').create(recursive: true);
            await File(
              '.quality-receipts/setup-${printer ? 'printer' : 'profile'}-${size.width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await pumpStillWidget(tester, const SizedBox());
      }
    });
  }
}
