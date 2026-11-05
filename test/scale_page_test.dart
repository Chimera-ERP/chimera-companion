import 'support/still_widget.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:chimera_companion/scale_page.dart';
import 'package:chimera_companion/scale_service.dart';
import 'package:chimera_companion/hardware/scale.dart';

class PreviewScale extends ScaleService {
  @override
  Future<void> restore() async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> scan() async {
    error = 'Activează Bluetooth și permite accesul.';
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final inter = FontLoader('packages/forui/Inter')
      ..addFont(rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'));
    await inter.load();
    const fonts = String.fromEnvironment('CAPTURE_FONT_PATH');
    if (fonts.isNotEmpty) {
      for (final entry in {
        'Ahem': 'Roboto-Regular.ttf',
        'Roboto': 'Roboto-Regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf',
      }.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(
            File(
              '$fonts/${entry.value}',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
      }
    }
  });
  for (final size in [const Size(390, 844), const Size(1000, 600)]) {
    testWidgets('scale setup empty, error and reading at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = PreviewScale();
      final theme = FTheme.neutral.dark.touch;
      final boundary = GlobalKey();
      await pumpStillWidget(
        tester,
        MaterialApp(
          theme: theme.toApproximateMaterialTheme(),
          builder: (_, child) => FTheme(data: theme, child: child!),
          home: RepaintBoundary(
            key: boundary,
            child: ScalePage(service: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, 'LAN')).enabled,
        false,
      );
      await tester.tap(find.text('Bluetooth'));
      await tester.pumpAndSettle();
      expect(find.text('Caută cântar'), findsOneWidget);
      await tester.tap(find.text('Caută cântar'));
      await tester.pumpAndSettle();
      expect(
        find.text('Activează Bluetooth și permite accesul.'),
        findsOneWidget,
      );
      service.selectedId = 'synthetic';
      service.selectedName = 'Acaia · exemplu';
      service.state = ScaleState.ready;
      service.error = null;
      service.reading = ScaleReading(
        deviceId: 'synthetic',
        net: '350.0',
        unit: ScaleUnit.g,
        stable: false,
        observedAt: DateTime.now(),
      );
      service.notifyListeners();
      await tester.pump();
      expect(find.text('350.0 g'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_SCALE_UI')) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('.quality-receipts').create(recursive: true);
          await File(
            '.quality-receipts/acaia-companion-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      service.reading = ScaleReading(
        deviceId: 'synthetic',
        net: '350.0',
        unit: ScaleUnit.g,
        stable: false,
        observedAt: DateTime.now().subtract(const Duration(seconds: 3)),
      );
      service.notifyListeners();
      await tester.pump();
      expect(find.text('— g'), findsOneWidget);
      await pumpStillWidget(tester, const SizedBox());
    });
  }
}
