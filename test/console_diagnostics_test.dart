import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:forui/forui.dart';
import 'package:chimera_companion/console/console_contract.dart';
import 'package:chimera_companion/console/console_icons.dart';
import 'package:chimera_companion/console/console_page.dart';
import 'package:chimera_companion/console/console_service.dart';
import 'package:chimera_companion/console/console_test_menu.dart';
import 'package:chimera_companion/console/ulanzi_adapter.dart';
import 'package:chimera_companion/console/ulanzi_protocol.dart';
import 'console_test.dart' show AdapterFixture, UsbFixture;

class SlowAdapter extends AdapterFixture {
  Completer<void>? pending;
  @override
  Future<void> display(ConsoleFrame frame) async {
    await super.display(frame);
    await pending?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('packages/forui/Inter')..addFont(
          rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'),
        ))
        .load();
  });
  test(
    'physical keys5/10 wrap diagnostic pages; other keys change only their icon',
    () {
      final menu = ConsoleTestMenu(random: Random(12));
      final initial = menu.frame;
      expect(initial.keys.length, 13);
      expect(initial.keys[4].icon, 'up');
      expect(initial.keys[9].icon, 'down');
      expect(
        initial.keys.every((k) => ConsoleKey.icons.contains(k.icon)),
        isTrue,
      );
      menu.press(9);
      expect(menu.page, 1);
      expect(menu.frame.title, contains('2/3'));
      expect(
        menu.frame.keys.map((k) => k.icon),
        isNot(initial.keys.map((k) => k.icon)),
      );
      menu.press(4);
      expect(menu.page, 0);
      menu.press(4);
      expect(menu.page, 2);
      menu.press(9);
      expect(menu.page, 0);
      final before = menu.frame;
      menu.press(0);
      expect(menu.frame.keys.first.icon, isNot(before.keys.first.icon));
      expect(menu.frame.keys.skip(1), before.keys.skip(1));
      final revision = menu.frame.revision;
      menu.press(13);
      menu.press(-1);
      expect(menu.frame.revision, revision);
    },
  );

  test(
    'idle test entry and diagnostics never emit KDS actions or steal its lease',
    () async {
      final adapter = AdapterFixture();
      final service = ConsoleService(adapter: adapter);
      final events = <Map<String, Object>>[];
      final subscription = service.events.listen(events.add);
      await service.connect('test');
      expect(adapter.screens.last.keys.first.label, 'Test KDS');
      adapter.input.add(0);
      await Future<void>.delayed(Duration.zero);
      expect(service.testing, isTrue);
      expect(service.acquire, throwsStateError);
      adapter.input.add(9);
      await Future<void>.delayed(Duration.zero);
      expect(service.title, contains('2/3'));
      expect(service.lastKey, 10);
      adapter.input.add(4);
      await Future<void>.delayed(Duration.zero);
      expect(service.title, contains('1/3'));
      expect(events, isEmpty);
      await service.stopTest();
      service.acquire();
      await service.show(
        const ConsoleFrame(1, 'Production', [
          ConsoleKey('start', 'Începe', 'start', true),
        ]),
      );
      final count = adapter.screens.length;
      await service.startTest();
      expect(service.testing, isFalse);
      expect(adapter.screens.length, count);
      adapter.input.add(0);
      await Future<void>.delayed(Duration.zero);
      expect(events.single['id'], 'start');
      await subscription.cancel();
      await service.close();
      await adapter.input.close();
    },
  );

  test(
    'raw USB key1 replaces idle ZIP with13 diagnostic icons and keys5/10 navigate',
    () async {
      final usb = UsbFixture();
      final adapter = UlanziAdapter(
        usb,
        render: (key) async =>
            Uint8List.fromList(utf8.encode('${key.label}:${key.icon}')),
      );
      final service = ConsoleService(transport: usb, adapter: adapter);
      Future<void> waitForUpload(int count) async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while ((adapter.diagnostics['uploads'] as int) < count) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Diagnostic screen not uploaded');
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      Map<String, String> screen() {
        final packets = usb.writes.lastWhere(
          (p) => UlanziProtocol.command(p.first) == 1,
        );
        final size = ByteData.sublistView(
          packets.first,
        ).getUint32(4, Endian.little);
        final zip = ZipDecoder().decodeBytes(
          [
            ...packets.first.skip(8),
            ...packets.skip(1).expand((p) => p),
          ].take(size).toList(),
        );
        final manifest =
            jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content))
                as Map<String, dynamic>;
        return {
          for (var i = 0; i < 13; i++)
            '${i % 5}_${i ~/ 5}': utf8.decode(
              zip
                  .findFile(
                    manifest['${i % 5}_${i ~/ 5}']['ViewParam'][0]['Icon']
                        as String,
                  )!
                  .content,
            ),
        };
      }

      try {
        await service.connect('test');
        expect(screen()['0_0'], 'Test KDS:open');
        usb.button(0, true);
        usb.button(0, false);
        await waitForUpload(2);
        expect(service.testing, isTrue);
        final icons = screen();
        expect(icons.values.toSet(), hasLength(13));
        expect(icons.values, isNot(contains('Test KDS:open')));
        expect(icons['4_0'], 'Sus:up');
        expect(icons['4_1'], 'Jos:down');
        usb.button(9, true);
        usb.button(9, false);
        await waitForUpload(3);
        expect(service.title, contains('2/3'));
        usb.button(4, true);
        usb.button(4, false);
        await waitForUpload(4);
        expect(service.title, contains('1/3'));
        expect(service.diagnostics['mode'], 'test');
        expect(service.diagnostics['lastKey'], 5);
        expect(adapter.diagnostics['buttonReports'], 6);
        expect(adapter.diagnostics['uploads'], 4);
      } finally {
        await service.close();
        await usb.input.close();
      }
    },
  );

  test(
    'diagnostic upload ignores repeated navigation and disconnect clears the mode',
    () async {
      final adapter = SlowAdapter();
      final console = ConsoleService(adapter: adapter);
      await console.connect('test');
      adapter.pending = Completer<void>();
      final upload = console.startTest();
      adapter.input.add(9);
      adapter.input.add(9);
      await Future<void>.delayed(Duration.zero);
      expect(console.title, contains('1/3'));
      await console.disconnect();
      adapter.pending!.complete();
      await upload;
      expect(console.testing, isFalse);
      expect(console.connected, isFalse);
      adapter.input.add(9);
      await Future<void>.delayed(Duration.zero);
      expect(console.testing, isFalse);
      await console.close();
      await adapter.input.close();
    },
  );

  test(
    'every enabled/disabled icon and blank key uses opaque pure black, not a gray tile',
    () async {
      for (final key in [
        for (final icon in ConsoleKey.icons)
          for (final enabled in [true, false])
            ConsoleKey('test', 'Test', icon, enabled),
        const ConsoleKey('empty', '', 'open', false),
      ]) {
        final codec = await ui.instantiateImageCodec(
          await renderConsoleKey(key),
        );
        final image = (await codec.getNextFrame()).image;
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        expect(image.width, 196);
        expect(image.height, 196);
        for (var y = 0; y < 196; y++) {
          for (final x in [0, 195]) {
            final offset = (y * 196 + x) * 4;
            expect(pixels.sublist(offset, offset + 4), [0, 0, 0, 255]);
          }
        }
        if (key.label.isEmpty) {
          for (var p = 0; p < pixels.length; p += 4) {
            expect(pixels.sublist(p, p + 4), [0, 0, 0, 255]);
          }
        }
        image.dispose();
        codec.dispose();
      }
      if (Platform.environment['CONSOLE_CAPTURE'] == '1') {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..drawColor(Colors.black, BlendMode.src);
        final keys = ConsoleTestMenu(random: Random(12)).frame.keys;
        final images = <ui.Image>[];
        for (var index = 0; index < keys.length; index++) {
          final codec = await ui.instantiateImageCodec(
            await renderConsoleKey(keys[index]),
          );
          final image = (await codec.getNextFrame()).image;
          images.add(image);
          canvas.drawImage(
            image,
            Offset(8 + (index % 5) * 204, 8 + (index ~/ 5) * 204),
            Paint(),
          );
          codec.dispose();
        }
        final picture = recorder.endRecording();
        final preview = await picture.toImage(1028, 620);
        final bytes = await preview.toByteData(format: ui.ImageByteFormat.png);
        final file = File('.quality-receipts/console-test-pictograms.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        for (final image in images) {
          image.dispose();
        }
        preview.dispose();
        picture.dispose();
      }
    },
  );

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
      'console diagnostics controls fit $size and return safely to idle',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final adapter = AdapterFixture();
        final service = ConsoleService(adapter: adapter);
        await service.connect('test');
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: FTheme.neutral.dark.touch.toApproximateMaterialTheme(),
            builder: (_, child) =>
                FTheme(data: FTheme.neutral.dark.touch, child: child!),
            home: RepaintBoundary(
              key: boundary,
              child: ConsolePage(service: service),
            ),
          ),
        );
        await tester.tap(find.text('Probă pictograme'));
        await tester.pumpAndSettle();
        expect(find.text('5 ↑ · 10 ↓'), findsOneWidget);
        expect(find.text('Probă pictograme · 1/3'), findsOneWidget);
        adapter.input.add(9);
        await tester.pumpAndSettle();
        expect(find.text('Probă pictograme · 2/3'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (Platform.environment['CONSOLE_CAPTURE'] == '1') {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              '.quality-receipts/console-diagnostics-${size.width.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.ensureVisible(find.text('Încheie proba'));
        await tester.tap(find.text('Încheie proba'));
        await tester.pumpAndSettle();
        expect(service.testing, isFalse);
        expect(find.text('Probă pictograme'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await service.close();
          await adapter.input.close();
        });
      },
    );
  }
}
