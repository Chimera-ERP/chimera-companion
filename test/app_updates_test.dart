import 'support/still_widget.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:chimera_companion/app_updates.dart';
import 'package:chimera_companion/update_release.dart';
import 'package:chimera_companion/companion_app_bar.dart';

class FakeUpdater extends CompanionUpdater {
  bool unavailable = false;
  bool allowed = false;
  int downloads = 0;
  CompanionRelease? release;
  final calls = <bool>[];
  @override
  Future<CompanionRelease?> check() async {
    calls.add(true);
    if (unavailable) throw Exception('offline');
    return release;
  }

  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<File> download(CompanionRelease release) async {
    downloads++;
    return File('/synthetic/companion.apk');
  }
}

void main() {
  testWidgets(
    'update action follows navigation and preserves the hardware gate',
    (tester) async {
      var updating = false;
      await pumpStillWidget(
        tester,
        MaterialApp(
          builder: (_, child) => CompanionUpdateScope(
            isBusy: () => false,
            setUpdating: (v) => updating = v,
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              appBar: const CompanionAppBar(title: Text('Setup')),
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: const CompanionAppBar(title: Text('Details')),
                    ),
                  ),
                ),
                child: const Text('Open details'),
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('Verifică actualizările'), findsOneWidget);
      await tester.tap(find.text('Open details'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Verifică actualizările'), findsOneWidget);
      await tester.tap(find.byTooltip('Verifică actualizările'));
      await tester.pumpAndSettle();
      expect(updating, true);
      expect(find.text('Actualizare Companion'), findsOneWidget);
      await tester.tap(find.text('Închide'));
      await tester.pumpAndSettle();
      expect(updating, false);
    },
  );
  testWidgets(
    'unpaired update dialog checks GitHub directly and supports offline retry',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final updater = FakeUpdater()..unavailable = true;
      await pumpStillWidget(
        tester,
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                CompanionUpdateButton(
                  isBusy: () => false,
                  setUpdating: (_) {},
                  updater: updater,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Verifică actualizările'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(updater.calls, hasLength(1));
      expect(find.textContaining('Nu pot verifica'), findsOneWidget);
      updater.unavailable = false;
      await tester.tap(find.text('Verifică acum'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Aplicația este la zi.'), findsOneWidget);
      expect(updater.calls, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Închide'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets('busy device cannot open update installer', (tester) async {
    await pumpStillWidget(
      tester,
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              CompanionUpdateButton(
                isBusy: () => true,
                setUpdating: (_) => fail('Must not suspend a busy device'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
  });
  final hash = List.filled(64, 'a').join();
  Map<String, dynamic> manifest() => {
    'version': 1,
    'packageName': 'ro.tabusociety.chimera_companion',
    'versionCode': 2,
    'versionName': '0.1.1',
    'size': 100,
    'sha256': hash,
    'url':
        'https://github.com/$companionReleaseRepository/releases/download/v0.1.1/companion-0.1.1.apk',
    'signingCertificateSha256': companionSigningCertificate,
  };
  for (final size in [
    const Size(360, 640),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets('update dialog preflights permission and resumes at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final updater = FakeUpdater()..release = CompanionRelease(manifest());
      final settings = <String>[];
      const channel = MethodChannel('chimera/settings');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            settings.add((call.arguments as Map)['page'] as String);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await pumpStillWidget(
        tester,
        MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(1.3),
            ),
            child: CompanionUpdateDialog(updater: updater),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(updater.calls, hasLength(1));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Instalează'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('Setări Android'));
      await tester.tap(find.text('Setări Android'));
      await tester.pumpAndSettle();
      expect(settings, ['install']);
      expect(updater.downloads, 0);
      updater.allowed = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Instalează'),
            )
            .onPressed,
        isNotNull,
      );
      // Permission can disappear between checking and the actual download.
      updater.allowed = false;
      await tester.tap(find.text('Instalează'));
      await tester.pumpAndSettle();
      expect(updater.downloads, 0);
      expect(
        find.text('Permite instalarea în setările Android.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getRect(
              find
                  .descendant(
                    of: find.byType(Dialog),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .width,
        lessThanOrEqualTo(560),
      );
      await pumpStillWidget(tester, const SizedBox());
    });
  }
  test('accepts versioned GitHub release APK', () {
    expect(CompanionRelease(manifest()).url.host, 'github.com');
  });
  for (final mutation in [
    {'url': 'https://evil.example/app.apk'},
    {'url': 'http://erp.example.com/app.apk'},
    {'url': '/api/companion-updates/$hash.apk?redirect=evil'},
    {'sha256': '../key'},
    {'packageName': 'other'},
    {'size': 300 * 1024 * 1024},
    {'size': 0},
    {'versionCode': 0},
  ]) {
    test('rejects invalid release $mutation', () {
      expect(
        () => CompanionRelease({...manifest(), ...mutation}),
        throwsFormatException,
      );
    });
  }
}
