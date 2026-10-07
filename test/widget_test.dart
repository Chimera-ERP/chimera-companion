import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/main.dart';
import 'package:chimera_companion/debug_panel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    debugMessages.value = [];
  });
  testWidgets(
    'Dark setup retains manual Datecs address and collapsible operator settings',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({
        'setup_step_v3': '2',
        'erp_pairing_v1':jsonEncode({'erp_url':'https://erp.example.test','token':'fixture',
          'device_id':'fixture-companion','location_id':'fixture-location'}),
        'local_hardware_v1': jsonEncode({
          'model': 'datecsDp25',
          'host': '192.168.1.25',
          'port': '3999',
        }),
      });
      await tester.pumpWidget(const CompanionApp());
      await tester.pumpAndSettle();
      expect(
        Theme.of(
          tester.element(find.text('Companion · configurare')),
        ).brightness,
        Brightness.dark,
      );
      expect(find.text('3 din 5'), findsOneWidget);
      expect(find.text('Verifică ECR'), findsOneWidget);
      final buttons = Theme.of(
        tester.element(find.text('Verifică ECR')),
      ).filledButtonTheme.style!;
      final foreground = buttons.foregroundColor!.resolve({})!;
      final background = buttons.backgroundColor!.resolve({})!;
      final contrast =
          (background.computeLuminance() + 0.05) /
          (foreground.computeLuminance() + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5));
      await tester.scrollUntilVisible(
        find.text('IP local ECR'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('IP local ECR'), findsOneWidget);
      expect(find.text('Port'), findsOneWidget);
      expect(find.text('Caută în rețea'), findsOneWidget);
      expect(find.text('Printează X'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Operator și setări avansate'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Operator și setări avansate'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Parolă operator fiscal'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Parolă operator fiscal'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog),findsOneWidget);
      final password = tester.widget<TextField>(
        find
            .ancestor(
              of: find.text('Parolă'),
              matching: find.byType(TextField),
            )
            .first,
      );
      expect(password.obscureText, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Fresh enrollment starts with ERP before TLS and hardware', (
    tester,
  ) async {
    await tester.pumpWidget(const CompanionApp());
    await tester.pumpAndSettle();
    expect(find.text('1 din 5'), findsOneWidget);
    expect(find.text('Conectare la Chimera'), findsOneWidget);
    expect(find.text('Verifică ECR'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Bottom debug history is bounded and independently scrollable', (
    tester,
  ) async {
    for (var i = 0; i < 250; i++) {
      debugLog('Mesaj $i');
    }
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DebugPanel())),
    );
    await tester.pumpAndSettle();
    expect(debugMessages.value.length, 200);
    expect(find.textContaining('Mesaj 249'), findsNothing);
    await tester.tap(find.byTooltip('Extinde debug'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mesaj 249'), findsOneWidget);
    await tester.drag(
      find.descendant(
        of: find.byType(DebugPanel),
        matching: find.byType(ListView),
      ),
      const Offset(0, 1000),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Mesaj 249'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
