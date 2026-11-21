import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chimera_companion/device_setup.dart';
import 'package:chimera_companion/main.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'support/still_widget.dart';
import 'package:chimera_companion/fp21_usb_dialog.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/fp21_usb.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Usb extends Fp21Usb {
  List<Fp21UsbDevice> attached = [];
  final probed = <String>[];
  var reply = Completer<DeviceStatus>();

  final printedDevices = <String>[];
  final commandIds = <String>[];
  final printReply = Completer<HardwareResult>();

  @override
  Future<HardwareResult> printTest(
    String deviceId, {
    required int operatorNumber,
    required String operatorPassword,
    required String commandId,
  }) {
    expect(operatorNumber, 2);
    expect(operatorPassword, 'TEST');
    printedDevices.add(deviceId);
    commandIds.add(commandId);
    return printReply.future;
  }

  final finished = <(String, String)>[];

  @override
  Future<HardwareResult> finishInterruptedTest(
    String deviceId,
    String originalId,
  ) {
    finished.add((deviceId, originalId));
    return printReply.future;
  }

  final directCommands = <(String, String, String)>[];
  var directReply = Completer<HardwareResult>();

  @override
  Future<HardwareResult> forceCloseNonFiscal(
    String deviceId,
    String commandId,
  ) {
    directCommands.add(('close', deviceId, commandId));
    return directReply.future;
  }

  @override
  Future<HardwareResult> printQrTest(String deviceId, String commandId) {
    directCommands.add(('qr', deviceId, commandId));
    return directReply.future;
  }

  @override
  Future<HardwareResult> cutPaper(String deviceId, String commandId) {
    directCommands.add(('cut', deviceId, commandId));
    return directReply.future;
  }

  @override
  Future<List<Fp21UsbDevice>> devices() async => attached;

  @override
  Future<DeviceStatus> probe(String deviceId) {
    probed.add(deviceId);
    return reply.future;
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_FP21_UI')) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')),
    );
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '.quality-receipts/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _openTestDialog(WidgetTester tester, _Usb usb) async {
  await pumpStillWidget(
    tester,
    RepaintBoundary(
      key: const ValueKey('capture'),
      child: CompanionApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Fp21UsbDialog(usb: usb),
              ),
              child: const Text('USB'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('USB'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_FP21_UI')) return;
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('packages/forui/Inter')..addFont(
          rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'),
        ))
        .load();
  });

  testWidgets('fresh installation can check USB before enrollment', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(Fp21Usb.channel, (call) async {
      calls.add(call.method);
      return [];
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(Fp21Usb.channel, null),
    );
    await pumpStillWidget(tester, const CompanionApp(home: DeviceSetupPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Testează Activa FP21 prin USB'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nicio imprimantă USB găsită.'), findsOneWidget);
    expect(calls, ['devices']);
    await tester.tap(find.text('Închide'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Testează Activa FP21 prin USB'), findsOneWidget);
    expect(
      await const FlutterSecureStorage().read(key: 'setup_complete_v2'),
      isNull,
    );
    expect(tester.takeException(), isNull);
    await pumpStillWidget(tester, const SizedBox());
  });

  for (final setup in [true, false]) {
    testWidgets(
      'USB diagnostics open from ${setup ? 'FP21 setup' : 'home'} and preserve enrolled settings',
      (tester) async {
        const saved =
            '{"model":"tremolFp21","host":"192.0.2.10","port":"8000"}';
        FlutterSecureStorage.setMockInitialValues({'local_hardware_v1': saved});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = setup
            ? const Size(360, 640)
            : const Size(1280, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(Fp21Usb.channel, (call) async {
          expect(call.method, 'devices');
          return [
            {'id': 'fixture-7', 'label': 'Tremol FP21'},
          ];
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(Fp21Usb.channel, null),
        );
        await pumpStillWidget(
          tester,
          RepaintBoundary(
            key: const ValueKey('capture'),
            child: CompanionApp(
              home: setup
                  ? const DeviceSetupPage(initialStep: 2)
                  : const CompanionHome(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (!setup) {
          await tester.tap(find.text('Casa de marcat'));
          await tester.pumpAndSettle();
        }
        final action = find.text('Diagnostic USB FP21');
        if (setup) {
          await tester.scrollUntilVisible(
            action,
            180,
            scrollable: find.byType(Scrollable).first,
          );
        }
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.byType(Fp21UsbDialog), findsOneWidget);
        expect(find.text('Tremol FP21'), findsOneWidget);
        await _capture(tester, 'fp21-usb-${setup ? 'narrow' : 'wide'}');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(
          await const FlutterSecureStorage().read(key: 'local_hardware_v1'),
          saved,
        );
        expect(tester.takeException(), isNull);
        await pumpStillWidget(tester, const SizedBox());
      },
    );
  }

  for (final size in [const Size(360, 640), const Size(1280, 800)]) {
    testWidgets(
      'explicit USB selection, permission retry and printer reply at $size',
      (tester) async {
        final usb = _Usb();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => Fp21UsbDialog(usb: usb),
                  ),
                  child: const Text('USB'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('USB'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Nicio imprimantă USB găsită.'),
          findsOneWidget,
        );
        expect(find.text('Citește starea'), findsNothing);
        usb.attached = [
          const Fp21UsbDevice(id: 'usb1', label: 'FP21 A'),
          const Fp21UsbDevice(id: 'usb2', label: 'FP21 B'),
        ];
        await tester.tap(find.text('Caută din nou'));
        await tester.pumpAndSettle();
        final read = find.widgetWithText(FilledButton, 'Citește starea');
        expect(tester.widget<FilledButton>(read).onPressed, isNull);
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('FP21 B').last);
        await tester.pumpAndSettle();
        await tester.tap(read);
        await tester.pump();
        expect(usb.probed, ['usb2']);
        expect(find.text('Se citește starea imprimantei…'), findsOneWidget);
        expect(tester.widget<FilledButton>(read).onPressed, isNull);
        usb.reply.completeError(
          PlatformException(
            code: 'permission_denied',
            message: 'Permite accesul USB în Android.',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Permite accesul USB în Android.'), findsOneWidget);
        usb.reply = Completer<DeviceStatus>();
        await tester.tap(read);
        await tester.pump();
        usb.reply.complete(
          const DeviceStatus(ready: false, description: 'Capac deschis'),
        );
        await tester.pumpAndSettle();
        expect(usb.probed, ['usb2', 'usb2']);
        expect(find.text('Tipărește bonul de test'), findsNothing);
        expect(find.text('Continuă bonul de test'), findsNothing);
        expect(
          find.text('Imprimanta a răspuns prin USB. Capac deschis'),
          findsOneWidget,
        );
        usb.attached = [];
        await tester.tap(find.text('Caută din nou'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Capac deschis'), findsNothing);
        await tester.tap(find.text('Închide'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final outcome in CommandOutcome.values) {
    testWidgets(
      'prints once for the verified selected FP21 and handles ${outcome.name}',
      (tester) async {
        final usb = _Usb()
          ..attached = [
            const Fp21UsbDevice(id: 'usb1', label: 'FP21 A'),
            const Fp21UsbDevice(id: 'usb2', label: 'FP21 B'),
          ]
          ..reply.complete(
            const DeviceStatus(ready: true, description: 'Pregătită'),
          );
        final narrow = outcome != CommandOutcome.succeeded;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = narrow
            ? const Size(360, 640)
            : const Size(1280, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _openTestDialog(tester, usb);
        final selector = find.byType(DropdownButtonFormField<String>);
        final printButton = find.widgetWithText(
          FilledButton,
          'Tipărește bonul de test',
        );
        final readButton = find.text('Citește starea');
        expect(printButton, findsNothing);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(find.text('FP21 A').last);
        await tester.pumpAndSettle();
        await tester.tap(readButton);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(printButton).onPressed, isNull);
        await tester.enterText(find.byType(TextField).last, 'AAAA');
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(find.text('FP21 B').last);
        await tester.pumpAndSettle();
        expect(printButton, findsNothing);
        await tester.tap(readButton);
        await tester.pumpAndSettle();
        expect(usb.probed, ['usb1', 'usb2']);
        final operator = find.byType(TextField).first;
        final password = find.byType(TextField).last;
        expect(tester.widget<TextField>(operator).controller!.text, '1');
        expect(tester.widget<TextField>(password).controller!.text, isEmpty);
        expect(tester.widget<TextField>(password).obscureText, isTrue);
        await _capture(tester, 'fp21-usb-print-${narrow ? 'narrow' : 'wide'}');
        await tester.enterText(operator, '21');
        await tester.enterText(password, 'TEST');
        await tester.pump();
        expect(tester.widget<FilledButton>(printButton).onPressed, isNull);
        await tester.enterText(operator, '2');
        await tester.pump();
        expect(tester.widget<FilledButton>(printButton).onPressed, isNotNull);
        expect(usb.printedDevices, isEmpty);
        await tester.tap(printButton);
        await tester.tap(printButton);
        await tester.pumpAndSettle();
        expect(usb.printedDevices, ['usb2']);
        expect(usb.commandIds.single, isNotEmpty);
        expect(
          find.text('Se tipărește bonul nefiscal de test…'),
          findsOneWidget,
        );
        expect(tester.widget<FilledButton>(printButton).onPressed, isNull);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Închide'))
              .onPressed,
          isNull,
        );
        await tester.tapAt(const Offset(2, 2));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(Fp21UsbDialog), findsOneWidget);
        usb.printReply.complete(
          HardwareResult(outcome, message: 'Rezultat de probă'),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Rezultat de probă'), findsOneWidget);
        expect(printButton, findsNothing);
        if (outcome == CommandOutcome.unknown) {
          expect(readButton, findsNothing);
          expect(
            find.textContaining('Verifică dacă bonul a ieșit complet'),
            findsOneWidget,
          );
          await tester.tap(find.text('Am verificat hârtia'));
          await tester.pumpAndSettle();
        }
        expect(readButton, findsOneWidget);
        expect(usb.printedDevices, ['usb2']);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(Fp21UsbDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final outcome in [CommandOutcome.succeeded, CommandOutcome.unknown]) {
    testWidgets(
      'only continues the identified local test after checking its paper (${outcome.name})',
      (tester) async {
        final usb = _Usb()
          ..attached = [const Fp21UsbDevice(id: 'fp21', label: 'Activa FP21')];
        final narrow = outcome == CommandOutcome.unknown;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = narrow
            ? const Size(360, 640)
            : const Size(1280, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const interrupted = DeviceStatus(
          ready: false,
          description:
              'Bon nefiscal deschis. Imprimanta a respins codul de bare.',
          details: {'interruptedTestId': 'original'},
        );
        const fiscalOpen = DeviceStatus(
          ready: false,
          description: 'Bon fiscal deschis',
        );
        await _openTestDialog(tester, usb);
        final read = find.text('Citește starea');
        final resume = find.widgetWithText(
          FilledButton,
          'Continuă bonul de test',
        );
        final paper = find.byType(CheckboxListTile);
        Future<void> probe(DeviceStatus status) async {
          usb.reply = Completer<DeviceStatus>()..complete(status);
          await tester.tap(read);
          await tester.pumpAndSettle();
        }

        await probe(fiscalOpen);
        expect(resume, findsNothing);
        expect(paper, findsNothing);
        await probe(interrupted);
        expect(find.textContaining('Cod de bare demonstrativ'), findsOneWidget);
        expect(find.textContaining(interrupted.description), findsOneWidget);
        expect(find.text('Tipărește bonul de test'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(tester.widget<FilledButton>(resume).onPressed, isNull);
        await tester.ensureVisible(paper);
        await tester.pumpAndSettle();
        await tester.tap(paper);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(resume).onPressed, isNotNull);
        await _capture(
          tester,
          'fp21-usb-recovery-${narrow ? 'narrow' : 'wide'}',
        );
        await tester.ensureVisible(find.text('Caută din nou'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Caută din nou'));
        await tester.pumpAndSettle();
        expect(resume, findsNothing);
        await probe(interrupted);
        expect(tester.widget<FilledButton>(resume).onPressed, isNull);
        await tester.ensureVisible(paper);
        await tester.pumpAndSettle();
        await tester.tap(paper);
        await tester.pumpAndSettle();
        await tester.tap(resume);
        await tester.tap(resume);
        await tester.pumpAndSettle();
        expect(usb.finished, [('fp21', 'original')]);
        expect(tester.widget<FilledButton>(resume).onPressed, isNull);
        expect(
          find.text('Se continuă bonul nefiscal de test…'),
          findsOneWidget,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(Fp21UsbDialog), findsOneWidget);
        usb.printReply.complete(
          HardwareResult(outcome, message: 'Rezultat recuperare'),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Rezultat recuperare'), findsOneWidget);
        expect(resume, findsNothing);
        if (outcome == CommandOutcome.unknown) {
          expect(read, findsNothing);
          await tester.tap(find.text('Am verificat hârtia'));
          await tester.pumpAndSettle();
        }
        expect(read, findsOneWidget);
        expect(usb.printedDevices, isEmpty);
        expect(usb.finished, [('fp21', 'original')]);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'standalone QR uses the selected printer without printing the basket',
    (tester) async {
      final usb = _Usb()
        ..attached = [
          const Fp21UsbDevice(id: 'fp21-usb9', label: 'Activa FP21'),
        ]
        ..reply.complete(
          const DeviceStatus(ready: true, description: 'Pregătită'),
        );
      await _openTestDialog(tester, usb);
      await tester.tap(find.text('Citește starea'));
      await tester.pumpAndSettle();
      final qr = find.text('Testează doar QR');
      await tester.ensureVisible(qr);
      await tester.pumpAndSettle();
      await tester.tap(qr);
      await tester.tap(qr);
      await tester.pumpAndSettle();
      expect(usb.directCommands.single.$1, 'qr');
      expect(usb.directCommands.single.$2, 'fp21-usb9');
      expect(usb.directCommands.single.$3, isNotEmpty);
      expect(usb.printedDevices, isEmpty);
      usb.directReply.complete(
        const HardwareResult(
          CommandOutcome.rejected,
          message: 'QR refuzat de FP21.',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('QR refuzat de FP21.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final cutFirst in [true, false]) {
    testWidgets(
      'direct printer commands work immediately after replug, starting with ${cutFirst ? 'cut' : 'close'}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = cutFirst
            ? const Size(360, 640)
            : const Size(1280, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final usb = _Usb()
          ..attached = [
            const Fp21UsbDevice(id: 'A', label: 'Imprimanta A'),
            const Fp21UsbDevice(id: 'B', label: 'Imprimanta B'),
          ];
        await _openTestDialog(tester, usb);
        final cut = find.widgetWithText(OutlinedButton, 'Taie hârtia');
        final close = find.widgetWithText(
          OutlinedButton,
          'Închide forțat bonul',
        );
        expect(cut, findsNothing);
        expect(close, findsNothing);
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Imprimanta B').last);
        await tester.pumpAndSettle();
        expect(tester.widget<OutlinedButton>(cut).onPressed, isNotNull);
        expect(tester.widget<OutlinedButton>(close).onPressed, isNotNull);
        usb.attached = [];
        await tester.tap(find.text('Caută din nou'));
        await tester.pumpAndSettle();
        expect(close, findsNothing);
        usb.attached = [
          const Fp21UsbDevice(id: 'new-attachment', label: 'Activa FP21'),
        ];
        await tester.tap(find.text('Caută din nou'));
        await tester.pumpAndSettle();
        expect(usb.probed, isEmpty);
        await _capture(
          tester,
          'fp21-usb-direct-${cutFirst ? 'narrow' : 'wide'}',
        );
        final first = cutFirst ? cut : close;
        final second = cutFirst ? close : cut;
        final commands = cutFirst ? ['cut', 'close'] : ['close', 'cut'];
        await tester.tap(first);
        await tester.tap(first);
        await tester.tap(second);
        await tester.pumpAndSettle();
        expect(
          find.text(
            cutFirst ? 'Se taie hârtia…' : 'Se închide bonul nefiscal…',
          ),
          findsOneWidget,
        );
        expect(usb.directCommands.length, 1);
        expect(usb.directCommands.single.$1, commands.first);
        expect(usb.directCommands.single.$2, 'new-attachment');
        expect(usb.directCommands.single.$3, isNotEmpty);
        expect(tester.widget<OutlinedButton>(close).onPressed, isNull);
        expect(tester.widget<OutlinedButton>(cut).onPressed, isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(Fp21UsbDialog), findsOneWidget);
        usb.directReply.complete(
          const HardwareResult(
            CommandOutcome.unknown,
            message: 'Confirmare lipsă.',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Confirmare lipsă.'), findsOneWidget);
        expect(find.text('Am verificat hârtia'), findsNothing);
        expect(find.text('Citește starea'), findsOneWidget);
        usb.directReply = Completer<HardwareResult>()
          ..complete(
            const HardwareResult(
              CommandOutcome.succeeded,
              message: 'Comandă confirmată.',
            ),
          );
        await tester.tap(second);
        await tester.pumpAndSettle();
        expect(find.text('Comandă confirmată.'), findsOneWidget);
        expect(usb.directCommands.map((call) => call.$1), commands);
        expect(
          usb.directCommands.map((call) => call.$2),
          everyElement('new-attachment'),
        );
        expect(usb.directCommands.map((call) => call.$3).toSet().length, 2);
        expect(usb.finished, isEmpty);
        expect(usb.printedDevices, isEmpty);
        expect(usb.probed, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
