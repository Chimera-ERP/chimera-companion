import 'support/still_widget.dart';
import 'package:chimera_companion/setup_header.dart';
import 'package:chimera_companion/companion_scene.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:flutter/services.dart';
import 'package:chimera_companion/tls_setup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/main.dart';
import 'package:chimera_companion/debug_panel.dart';
import 'package:chimera_companion/device_setup.dart';
import 'package:chimera_companion/customer_display.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    debugMessages.value = [];
  });
  for (final (step, gear, scene) in [
    (7, <int>[7], CompanionSceneState.printer),
    (10, <int>[10], CompanionSceneState.keyboard),
    (6, <int>[6, 7], CompanionSceneState.scale),
  ]) {
    testWidgets(
      'selected equipment drives navigation and scene at step $step',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        FlutterSecureStorage.setMockInitialValues({
          'setup_step_v3': '$step',
          'setup_profile_v1': jsonEncode({
            'version': 2,
            'audience': 'back',
            'profile': 'kds',
            'devices': gear,
          }),
          'erp_pairing_v1': jsonEncode({
            'erp_url': 'https://erp.example.test',
            'token': 'fixture',
            'device_id': 'fixture',
            'location_id': 'fixture',
          }),
        });
        await pumpStillWidget(tester, const CompanionApp());
        await tester.pumpAndSettle();
        final header = find.byType(SetupHeader);
        expect(
          find.descendant(
            of: header,
            matching: find.textContaining(RegExp(r'\d+ din \d+')),
          ),
          findsNothing,
        );
        expect(
          tester
              .widget<CompanionScene>(find.byKey(const ValueKey('setup-scene')))
              .scene,
          scene,
        );
        final heroState = tester.state(
          find.byKey(const ValueKey('setup-scene')),
        );
        final back = find.byTooltip('Înapoi');
        expect(tester.getRect(back).top, lessThan(60));
        final next = find.widgetWithText(FilledButton, 'Mai târziu');
        expect(tester.getRect(next).height, greaterThanOrEqualTo(56));
        expect(tester.getRect(next).width, greaterThan(330));
        await tester.tap(next);
        await tester.pumpAndSettle();
        expect(
          await const FlutterSecureStorage().read(key: 'setup_step_v3'),
          step == 6 ? '7' : '4',
        );
        expect(
          tester.state(find.byKey(const ValueKey('setup-scene'))),
          same(heroState),
        );
        await tester.tap(find.byTooltip('Înapoi'));
        await tester.pumpAndSettle();
        expect(
          await const FlutterSecureStorage().read(key: 'setup_step_v3'),
          '$step',
        );
        expect(tester.takeException(), isNull);
        await pumpStillWidget(tester, const SizedBox());
      },
    );
  }
  testWidgets(
    'Dark setup retains manual Datecs address and modal operator settings',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({
        'setup_step_v3': '2',
        'erp_pairing_v1': jsonEncode({
          'erp_url': 'https://erp.example.test',
          'token': 'fixture',
          'device_id': 'fixture-companion',
          'location_id': 'fixture-location',
        }),
        'local_hardware_v1': jsonEncode({
          'model': 'datecsDp25',
          'host': '192.168.1.25',
          'port': '3999',
        }),
      });
      await pumpStillWidget(tester, const CompanionApp());
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('Configurare'))).brightness,
        Brightness.dark,
      );
      expect(
        find.descendant(
          of: find.byType(SetupHeader),
          matching: find.text('Casa de marcat'),
        ),
        findsOneWidget,
      );
      expect(find.text('Verifică ECR'), findsOneWidget);
      final buttons = Theme.of(
        tester.element(find.text('Verifică ECR')),
      ).filledButtonTheme.style!;
      final foreground = buttons.foregroundColor!.resolve({})!;
      final background = buttons.backgroundColor!.resolve({})!;
      final luminances = [
        background.computeLuminance(),
        foreground.computeLuminance(),
      ]..sort();
      final contrast = (luminances.last + 0.05) / (luminances.first + 0.05);
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
        find.text('Parolă operator fiscal').hitTestable(),
        100,
        scrollable: find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Parolă operator fiscal'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final password = tester.widget<TextField>(
        find
            .ancestor(of: find.text('Parolă'), matching: find.byType(TextField))
            .first,
      );
      expect(password.obscureText, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Fresh enrollment starts at PIN before role, TLS and hardware', (
    tester,
  ) async {
    await pumpStillWidget(tester, const CompanionApp());
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(SetupHeader),
        matching: find.text('Conectare la Chimera'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining(RegExp(r'\d+ din \d+')), findsNothing);
    expect(find.byTooltip('Verifică actualizările'), findsOneWidget);
    expect(find.text('PIN de conectare'), findsOneWidget);
    expect(find.text('Verifică ECR'), findsNothing);
    expect(find.text('Adresa ERP a companiei'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Back-of-house choices persist without altering saved hardware', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'setup_step_v3': '5',
      'erp_pairing_v1': jsonEncode({
        'erp_url': 'https://erp.example.test',
        'token': 'fixture',
        'device_id': 'fixture',
        'location_id': 'fixture',
      }),
      'local_hardware_v1': '{"host":"192.168.1.25","model":"tremolM20"}',
    });
    await pumpStillWidget(tester, const CompanionApp());
    await tester.pumpAndSettle();
    expect(find.text('În producție'), findsOneWidget);
    await tester.ensureVisible(find.text('În producție'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('În producție'));
    await tester.tap(find.text('Continuă'));
    await tester.pumpAndSettle();
    expect(find.text('KDS'), findsOneWidget);
    expect(find.text('PDS'), findsOneWidget);
    expect(
      find.widgetWithText(CheckboxListTile, 'Casa de marcat'),
      findsNothing,
    );
    expect(
      find.widgetWithText(CheckboxListTile, 'Terminal de plată'),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(CheckboxListTile, 'Imprimantă producție'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.widgetWithText(CheckboxListTile, 'Imprimantă producție'),
      findsOneWidget,
    );
    final hero = find.byKey(const ValueKey('setup-scene'), skipOffstage: false);
    expect(tester.widget<CompanionScene>(hero).equipment, {6, 7, 10});
    final keyboard = find.widgetWithText(CheckboxListTile, 'Tastatură custom');
    await tester.ensureVisible(keyboard);
    await tester.pumpAndSettle();
    await tester.tap(keyboard);
    await tester.pumpAndSettle();
    expect(tester.widget<CompanionScene>(hero).equipment, {6, 7});
    await tester.tap(keyboard);
    await tester.pumpAndSettle();
    expect(tester.widget<CompanionScene>(hero).equipment, {6, 7, 10});
    final saved = jsonDecode(
      (await const FlutterSecureStorage().read(key: 'setup_profile_v1'))!,
    );
    expect(saved['profile'], 'kds');
    expect(saved['audience'], 'back');
    expect(
      await const FlutterSecureStorage().read(key: 'local_hardware_v1'),
      '{"host":"192.168.1.25","model":"tremolM20"}',
    );
    expect(tester.takeException(), isNull);
    await pumpStillWidget(tester, const SizedBox());
  });
  testWidgets(
    'network settings expose Wi-Fi and keep manual TLS inside a modal',
    (tester) async {
      const channel = MethodChannel('chimera/settings');
      final pages = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        pages.add((call.arguments as Map)['page'] as String);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await pumpStillWidget(
        tester,
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TlsSetup(
                detectAddress: () async =>
                    throw Exception('fixture network unavailable'),
                onCompleted: () => fail('No certificate fixture was installed'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Certificat administrat manual'), findsNothing);
      await tester.tap(find.text('Avansat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Setări Wi-Fi'));
      await tester.pumpAndSettle();
      expect(pages, ['wifi']);

      await tester.tap(find.text('Certificat administrat manual'));
      await tester.pumpAndSettle();
      expect(find.text('CSR și certificat individual'), findsOneWidget);
      expect(find.text('Securizează conexiunea'), findsNothing);
      await tester.tap(find.text('Închide'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Reverifică rețeaua'), findsNothing);
      expect(find.text('Avansat'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await pumpStillWidget(tester, const SizedBox());
    },
  );
  for (final size in [
    const Size(360, 640),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'ECR can be skipped, draft retained, Viva hidden when unused at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await pumpStillWidget(
          tester,
          MaterialApp(
            theme: ThemeData.dark(),
            builder: (_, child) =>
                FTheme(data: FTheme.neutral.dark.touch, child: child!),
            home: const DeviceSetupPage(initialStep: 2),
          ),
        );
        await tester.pumpAndSettle();
        final host = find.widgetWithText(TextField, 'IP local ECR');
        await tester.scrollUntilVisible(
          host,
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(host, '192.168.1.172');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.scrollUntilVisible(
          find.text('Operator și setări avansate'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Operator și setări avansate'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Operator'), findsOneWidget);
        await tester.tap(find.text('Gata'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mai târziu'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(SetupHeader),
            matching: find.text('Terminal de plată'),
          ),
          findsOneWidget,
        );
        expect(find.text('IP local Viva'), findsNothing);
        expect(
          await const FlutterSecureStorage().read(key: 'local_hardware_v1'),
          isNull,
        );
        await tester.tap(find.byTooltip('Înapoi'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          host,
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          tester.widget<TextField>(host).controller!.text,
          '192.168.1.172',
        );
        await tester.tap(find.text('Mai târziu'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mai târziu'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(SetupHeader),
            matching: find.text('Cântar'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Mai târziu'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(SetupHeader),
            matching: find.text('Verificare finală'),
          ),
          findsOneWidget,
        );
        final settings = jsonDecode(
          (await const FlutterSecureStorage().read(key: 'local_hardware_v1'))!,
        );
        expect(settings['vivaEnabled'], 'false');
        expect(settings.containsKey('host'), false);
        expect(find.text('Finalizează'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'skipping preserves saved ECR and exposes background display permission during setup',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'local_hardware_v1': jsonEncode({
          'model': 'tremolM20',
          'host': '192.168.1.172',
          'port': '8000',
        }),
      });
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CustomerDisplay.channel, (call) async {
            calls.add(call.method);
            return {
              'state': 'ready',
              'enabled': true,
              'backgroundAllowed': false,
              'displays': [],
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(CustomerDisplay.channel, null),
      );
      await pumpStillWidget(
        tester,
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (_, child) =>
              FTheme(data: FTheme.neutral.dark.touch, child: child!),
          home: const DeviceSetupPage(initialStep: 2),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ecran client'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Permite afișarea în fundal'));
      await tester.pumpAndSettle();
      expect(calls, contains('permission'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mai târziu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mai târziu'));
      await tester.pumpAndSettle();
      final saved = jsonDecode(
        (await const FlutterSecureStorage().read(key: 'local_hardware_v1'))!,
      );
      expect(saved['host'], '192.168.1.172');
      expect(saved['port'], '8000');
      expect(tester.takeException(), isNull);
      await pumpStillWidget(tester, const SizedBox());
    },
  );
  testWidgets('Bottom debug history is bounded and independently scrollable', (
    tester,
  ) async {
    for (var i = 0; i < 250; i++) {
      debugLog('Mesaj $i');
    }
    await pumpStillWidget(
      tester,
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
