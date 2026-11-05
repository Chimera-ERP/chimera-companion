import 'support/still_widget.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/connection_status.dart';
import 'package:chimera_companion/main.dart';
import 'package:chimera_companion/customer_display.dart';
import 'package:chimera_companion/customer_display_page.dart';
import 'package:chimera_companion/scale_page.dart';

void main() {
  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('CAPTURE_HOME_UI')) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('.quality-receipts').create(recursive: true);
      await File(
        '.quality-receipts/scale-home-$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_HOME_UI')) return;
    final font = FontLoader('packages/forui/Inter')
      ..addFont(rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'));
    await font.load();
  });
  testWidgets('scale opens from home in shared wide and narrow detail', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpStillWidget(
      tester,
      MaterialApp(
        builder: (_, child) =>
            FTheme(data: FTheme.neutral.dark.touch, child: child!),
        theme: FTheme.neutral.dark.touch.toApproximateMaterialTheme(),
        home: const RepaintBoundary(child: CompanionHome()),
      ),
    );
    await tester.pumpAndSettle();
    await capture(tester, 'wide');
    await tester.tap(find.text('Cântar'));
    await tester.pumpAndSettle();
    expect(tester.widget<ScalePage>(find.byType(ScalePage)).embedded, true);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.text('POS'), findsOneWidget);
    await tester.tap(find.text('Bluetooth'));
    await tester.pumpAndSettle();
    expect(find.text('Caută cântar'), findsOneWidget);
    await capture(tester, 'detail-wide');
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.text('POS'), findsNothing);
    expect(find.text('Caută cântar'), findsOneWidget);
    await tester.tap(find.byTooltip('Înapoi'));
    await tester.pumpAndSettle();
    expect(find.text('Cântar'), findsOneWidget);
    expect(find.byType(ScalePage), findsNothing);
    await capture(tester, 'narrow');
    expect(tester.takeException(), isNull);
    await pumpStillWidget(tester, const SizedBox());
  });
  testWidgets(
    'display detail stays in the wide shell and survives narrow resize',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            CustomerDisplay.channel,
            (call) async => {
              'state': 'ready',
              'enabled': true,
              'backgroundAllowed': true,
              'displays': [],
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(CustomerDisplay.channel, null),
      );
      await pumpStillWidget(
        tester,
        MaterialApp(
          builder: (_, child) =>
              FTheme(data: FTheme.neutral.dark.touch, child: child!),
          home: const CompanionHome(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ecran client'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CustomerDisplayPage>(find.byType(CustomerDisplayPage))
            .embedded,
        true,
      );
      expect(find.text('POS'), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text('Conectat · așteaptă coșul'), findsOneWidget);
      tester.view.physicalSize = const Size(360, 640);
      await tester.pumpAndSettle();
      expect(find.byType(CustomerDisplayPage), findsOneWidget);
      expect(find.text('POS'), findsNothing);
      await tester.tap(find.byTooltip('Înapoi'));
      await tester.pumpAndSettle();
      expect(find.text('POS'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await pumpStillWidget(tester, const SizedBox());
    },
  );
  testWidgets(
    'connection indicators stack in portrait and align in landscape',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> show(Size size) async {
        tester.view.physicalSize = size;
        await pumpStillWidget(
          tester,
          const MaterialApp(
            home: Scaffold(
              body: ConnectionIndicators(
                states: {'ECR': true, 'POS': false, 'Chimera': null},
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await show(const Size(390, 844));
      expect(find.text('Fără activitate recentă'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('Conexiune indisponibilă'), findsNothing);
      expect(
        tester.getCenter(find.text('Casă de marcat')).dy,
        lessThan(tester.getCenter(find.text('Aplicația POS')).dy),
      );
      expect(
        tester.getCenter(find.text('Aplicația POS')).dy,
        lessThan(tester.getCenter(find.text('Chimera ERP')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Casă de marcat')).dx,
        tester.getTopLeft(find.text('Aplicația POS')).dx,
      );
      await show(const Size(844, 390));
      expect(
        tester.getCenter(find.text('Casă de marcat')).dy,
        tester.getCenter(find.text('Aplicația POS')).dy,
      );
      expect(
        tester.getCenter(find.text('Casă de marcat')).dx,
        lessThan(tester.getCenter(find.text('Aplicația POS')).dx),
      );
      expect(
        tester.getCenter(find.text('Aplicația POS')).dx,
        lessThan(tester.getCenter(find.text('Chimera ERP')).dx),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home has connection rows and opens diagnostics without operational buttons',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await pumpStillWidget(
        tester,
        MaterialApp(
          builder: (_, child) =>
              FTheme(data: FTheme.neutral.dark.touch, child: child!),
          home: const CompanionHome(),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in [
        'Asociere ERP',
        'Dispozitive ECR și Viva',
        'Catalog Tremol',
      ]) {
        expect(find.text(label), findsNothing);
      }
      expect(find.text('Raport X'), findsNothing);
      expect(find.text('Închide ziua · Z'), findsNothing);
      expect(find.text('Casa de marcat'), findsOneWidget);
      expect(find.text('Terminal de plată'), findsOneWidget);
      expect(find.text('POS'), findsOneWidget);
      expect(find.text('Cântar'), findsOneWidget);
      await tester.tap(find.byTooltip('Mai multe'));
      await tester.pumpAndSettle();
      expect(find.text('Cântar Bluetooth'), findsNothing);
      await tester.tap(find.text('Diagnostic'));
      await tester.pumpAndSettle();
      expect(find.text('Doar probleme'), findsOneWidget);
      expect(find.byTooltip('Verifică actualizările'), findsOneWidget);
      expect(find.text('Mesaje conexiune'), findsOneWidget);
      await pumpStillWidget(tester, const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
