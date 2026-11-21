import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chimera_companion/android_settings.dart';
import 'package:chimera_companion/device_setup.dart';
import 'package:chimera_companion/fp21_bluetooth_dialog.dart';
import 'package:chimera_companion/hardware/tremol_adapter.dart';
import 'package:chimera_companion/hardware/fiscal_serial.dart';
import 'package:chimera_companion/hardware/tremol_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:chimera_companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'adapters_test.dart' show TremolPeer;
import 'datecs_device_client_test.dart' show Peer;
import 'support/still_widget.dart';

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label).last;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_FISCAL_CONNECTION')) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('screen')),
    );
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '.quality-receipts/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

const _fiscalSerial = 'TEST0000001';

Future<List<int>> _fp21Reply(TremolPeer fp21, Uint8List frame) async {
  if (frame.length > 3 && frame[3] == 0x60) {
    return TremolProtocol.encode(frame[2], 0x60, ascii.encode(_fiscalSerial));
  }
  return fp21.exchange(frame, (_) => null);
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

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'FP21 Bluetooth on a ${width.toInt()}px screen reads before activation and recovers a missing response',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 720);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final firstRead = Completer<Fp21BluetoothState>();
        final enableReply = Completer<Fp21BluetoothState>();
        var reads = 0, writes = 0;
        final pages = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(AndroidSettings.channel, (
          method,
        ) async {
          pages.add(method.arguments['page'] as String);
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(AndroidSettings.channel, null),
        );
        await pumpStillWidget(
          tester,
          RepaintBoundary(
            key: const ValueKey('screen'),
            child: CompanionApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => Fp21BluetoothDialog(
                        readState: () async => ++reads == 1
                            ? firstRead.future
                            : Fp21BluetoothState.enabled,
                        enable: () {
                          writes++;
                          return enableReply.future;
                        },
                      ),
                    ),
                    child: const Text('Deschide configurarea'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Deschide configurarea'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(reads, 1);
        expect(writes, 0);
        expect(find.text('Activează Bluetooth'), findsNothing);
        firstRead.complete(Fp21BluetoothState.disabled);
        await tester.pumpAndSettle();
        await _capture(tester, 'fp21-radio-disabled-${width.toInt()}');
        await tester.tap(find.text('Activează Bluetooth'));
        await tester.pump();
        expect(writes, 1);
        expect(find.text('Activează Bluetooth'), findsNothing);
        enableReply.complete(Fp21BluetoothState.unconfirmed);
        await tester.pumpAndSettle();
        expect(find.text('Setări Bluetooth Android'), findsNothing);
        await _tap(tester, 'Verifică din nou');
        expect(reads, 2);
        expect(writes, 1);
        await _capture(tester, 'fp21-radio-ready-${width.toInt()}');
        await _tap(tester, 'Setări Bluetooth Android');
        expect(pages, ['bluetooth']);
        await _tap(tester, 'Închide');
        expect(find.text('Deschide configurarea'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (state, message) in [
    (Fp21BluetoothState.moduleAbsent, 'nu raportează un modul'),
    (Fp21BluetoothState.unsupportedFirmware, 'versiune de firmware'),
  ]) {
    testWidgets(
      'FP21 without Bluetooth configuration reports ${state.name} without an enable action',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Fp21BluetoothDialog(
              readState: () async => state,
              enable: () => throw StateError('Unexpected write'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining(message), findsOneWidget);
        expect(find.text('Activează Bluetooth'), findsNothing);
        expect(find.text('Setări Bluetooth Android'), findsNothing);
      },
    );
  }

  for (final usb in [true, false]) {
    final transport = usb ? 'usb' : 'bluetooth';
    final label = usb ? 'USB' : 'Bluetooth';
    testWidgets(
      'normal $transport setup selects, verifies, saves, and restores the identified register',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = usb
            ? const Size(360, 720)
            : const Size(1280, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final model = usb ? 'tremolFp21' : 'datecsDp25';
        final stable = usb
            ? sha256
                  .convert(utf8.encode('fiscal/tremolFp21/$_fiscalSerial'))
                  .toString()
            : '02:10:20:30:40:50';
        final name = usb ? 'Activa FP21' : 'Datecs DP-25 MX';
        final initial = jsonEncode({
          'model': model,
          'host': '192.168.1.13',
          'port': '8000',
          'vivaEnabled': 'true',
          'vivaHost': '127.0.0.1',
          'vivaPort': '9564',
          'tcpPassword': 'old-network',
        });
        FlutterSecureStorage.setMockInitialValues({
          'local_hardware_v1': initial,
        });
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final openedSettings = <String>[];
        var nearbyGranted = false;
        messenger.setMockMethodCallHandler(AndroidSettings.channel, (
          call,
        ) async {
          if (call.method == 'sdkInt') return 31;
          openedSettings.add(call.arguments['page'] as String);
          return null;
        });
        const permissions = MethodChannel(
          'flutter.baseflow.com/permissions/methods',
        );
        messenger.setMockMethodCallHandler(permissions, (call) async {
          expect(call.method, 'requestPermissions');
          expect(call.arguments, [Permission.bluetoothConnect.value]);
          return {Permission.bluetoothConnect.value: nearbyGranted ? 1 : 0};
        });
        final listed = Completer<void>();
        var attempts = 0;
        var firstSelection = true;
        final opens = <Map<dynamic, dynamic>>[];
        final fp21 = TremolPeer()..statusBytes[0] = 2;
        final mx = Peer();
        List<int> reply = [];
        messenger.setMockMethodCallHandler(FiscalSerial.channel, (call) async {
          final args = call.arguments as Map;
          switch (call.method) {
            case 'devices':
              expect(args['transport'], transport);
              if (++attempts == 1) {
                await listed.future;
                return [];
              }
              return [
                {'id': 'attachment-1', 'label': name},
              ];
            case 'select':
              expect(args['id'], 'attachment-1');
              expect(args['model'], model);
              if (firstSelection) {
                firstSelection = false;
                throw PlatformException(
                  code: 'permission',
                  message: 'Acces refuzat',
                );
              }
              return usb ? '' : stable;
            case 'openCandidate':
              expect(args['id'], 'attachment-1');
              expect(args['baudRate'], 115200);
              return 7;
            case 'bindCandidate':
              expect(args['id'], stable);
              return null;
            case 'open':
              opens.add(args);
              expect(args['transport'], transport);
              expect(args['id'], stable);
              return 7;
            case 'write':
              final frame = args['bytes'] as Uint8List;
              reply = await (usb
                  ? _fp21Reply(fp21, frame)
                  : mx.exchange(frame, (_) => null));
              return null;
            case 'read':
              expect(reply, isNotEmpty);
              final bytes = Uint8List.fromList(reply);
              reply = [];
              return bytes;
            case 'close':
              return null;
            default:
              fail('Unexpected method ${call.method}');
          }
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(FiscalSerial.channel, null);
          messenger.setMockMethodCallHandler(AndroidSettings.channel, null);
          messenger.setMockMethodCallHandler(permissions, null);
        });
        await pumpStillWidget(
          tester,
          RepaintBoundary(
            key: const ValueKey('screen'),
            child: CompanionApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const DeviceSetupPage(
                          initialStep: 2,
                          editRegister: true,
                        ),
                      ),
                    ),
                    child: const Text('Configurează casa'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tap(tester, 'Configurează casa');
        await _tap(tester, 'LAN / Wi-Fi');
        await _tap(tester, label);
        expect(find.text('IP local ECR'), findsNothing);
        final choose = find.text('Alege casa $label');
        await tester.tap(choose);
        await tester.pump(const Duration(milliseconds: 300));
        if (!usb) {
          await tester.pumpAndSettle();
          expect(attempts, 0);
          await _tap(tester, 'Permisiuni aplicație');
          expect(openedSettings, ['app']);
          nearbyGranted = true;
          await tester.tap(find.text('Actualizează'));
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(find.text('Se încarcă dispozitivele…'), findsOneWidget);
        listed.complete();
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            usb
                ? 'Conectează casa la portul USB'
                : 'Asociază casa în setările Bluetooth',
          ),
          findsOneWidget,
        );
        if (!usb) {
          await _tap(tester, 'Setări Bluetooth');
          expect(openedSettings, ['app', 'bluetooth']);
        }
        await _tap(tester, 'Actualizează');
        await _tap(tester, name);
        expect(find.text('Acces refuzat'), findsOneWidget);
        await _capture(tester, 'fiscal-$transport-denied');
        await _tap(tester, name);
        expect(find.text('Schimbă dispozitivul'), findsOneWidget);
        expect(
          await const FlutterSecureStorage().read(key: 'local_hardware_v1'),
          initial,
        );
        expect(
          find.text('Bluetooth pe Activa FP21'),
          usb ? findsOneWidget : findsNothing,
        );
        expect(opens, isEmpty);
        await _tap(tester, 'Verifică ECR');
        if (usb) {
          await tester.scrollUntilVisible(
            find.textContaining('Tremol blocat'),
            150,
            maxScrolls: 8,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.textContaining('Tremol blocat'), findsOneWidget);
          expect(fp21.commands, [0x20, 0x6a]);
        } else {
          expect(
            mx.requests.map(
              (request) => request
                  .sublist(6, 10)
                  .fold<int>(0, (n, b) => (n << 4) + b - 0x30),
            ),
            [76, ...List.filled(6, 255)],
          );
        }
        await tester.ensureVisible(find.text('Schimbă dispozitivul'));
        await tester.pumpAndSettle();
        await _capture(tester, 'fiscal-$transport-configured');
        await _tap(tester, 'Salvează conexiunea');
        expect(find.text('Configurează casa'), findsOneWidget);
        final saved =
            jsonDecode(
                  (await const FlutterSecureStorage().read(
                    key: 'local_hardware_v1',
                  ))!,
                )
                as Map;
        expect(saved['deviceId'], stable);
        expect(saved['deviceLabel'], name);
        expect(saved['transport'], transport);
        expect(saved['host'], isNull);
        expect(saved['port'], isNull);
        expect(saved['tcpPassword'], isNull);
        expect(saved['vivaHost'], '127.0.0.1');
        if (usb) {
          expect(saved['baudRate'], '115200');
        } else {
          expect(saved['datecsProfile'], 'asciiMx');
          expect(saved['baudRate'], isNull);
        }
        final beforeReopen = opens.length;
        await _tap(tester, 'Configurează casa');
        await tester.scrollUntilVisible(
          find.text('$transport:$stable'),
          140,
          maxScrolls: 8,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('$transport:$stable'), findsOneWidget);
        expect(find.text('Verifică ECR'), findsOneWidget);
        expect(opens, hasLength(beforeReopen));
        expect(tester.takeException(), isNull);
        await pumpStillWidget(tester, const SizedBox());
      },
    );
  }
  for (final usb in [true, false]) {
    final transport = usb ? 'usb' : 'bluetooth';
    final label = usb ? 'USB' : 'Bluetooth';
    testWidgets('Datecs ROU uses its selected SDK register on $transport', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      FlutterSecureStorage.setMockInitialValues({
        'local_hardware_v1':
            '{"model":"datecsDp25","host":"192.168.1.11","port":"3999"}',
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        AndroidSettings.channel,
        (c) async => 30,
      );
      final id = usb ? '1' * 64 : '02:00:00:00:00:03';
      final operations = <String>[];
      var bindings = 0;
      messenger.setMockMethodCallHandler(FiscalSerial.channel, (call) async {
        final args = call.arguments as Map;
        switch (call.method) {
          case 'devices':
            return [
              {'id': 'selection', 'label': 'Datecs ROU de probă'},
            ];
          case 'select':
            return usb ? '' : id;
          case 'legacyBind':
            expect(usb, isTrue);
            expect(args['id'], 'selection');
            expect(args['baudRate'], 115200);
            bindings++;
            return id;
          case 'legacyOperation':
            expect(args['id'], id);
            expect(args['transport'], transport);
            operations.add(args['operation'] as String);
            expect(args['operation'], 'status');
            return {
              'ready': true,
              'protocolConfirmed': true,
              'description': 'Pregătit',
            };
          default:
            fail('Unexpected operation ${call.method} on selected Datecs ROU');
        }
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(FiscalSerial.channel, null);
        messenger.setMockMethodCallHandler(AndroidSettings.channel, null);
      });
      await pumpStillWidget(
        tester,
        const CompanionApp(home: DeviceSetupPage(initialStep: 2)),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'LAN / Wi-Fi');
      await _tap(tester, label);
      if (!usb) {
        await _tap(tester, 'Alege casa Bluetooth');
        await _tap(tester, 'Datecs ROU de probă');
        expect(find.text('Verifică ECR'), findsOneWidget);
      }
      await _tap(tester, 'ASCII / MX');
      await _tap(tester, 'ROU vechi');
      expect(find.text('Alege casa $label'), findsOneWidget);
      await _tap(tester, 'Alege casa $label');
      await _tap(tester, 'Datecs ROU de probă');
      await _tap(tester, 'Verifică ECR');
      await _tap(tester, 'Continuă');
      final active =
          jsonDecode(
                (await const FlutterSecureStorage().read(
                  key: 'local_hardware_v1',
                ))!,
              )
              as Map;
      expect(active['datecsProfile'], 'legacyRou');
      expect(active['cashCode'], 'P');
      expect(active['cardCode'], 'D');
      expect(active['deviceId'], id);
      expect(active['transport'], transport);
      expect(bindings, usb ? 1 : 0);
      expect(operations, ['status']);
      expect(tester.takeException(), isNull);
      await pumpStillWidget(tester, const SizedBox());
    });
  }

  for (final existingRegister in [false, true]) {
    testWidgets(
      'PIN configures USB locally and retains its draft, existing register=$existingRegister',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        const storage = FlutterSecureStorage();
        const active =
            '{"model":"datecsDp25","host":"192.168.4.3","port":"3999","password":"8765","tcpPassword":"network","vivaEnabled":"true"}';
        FlutterSecureStorage.setMockInitialValues({
          'setup_step_v3': '0',
          if (existingRegister) 'local_hardware_v1': active,
        });
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final peer = TremolPeer();
        final stable = sha256
            .convert(utf8.encode('fiscal/tremolFp21/$_fiscalSerial'))
            .toString();
        List<int> reply = [];
        messenger.setMockMethodCallHandler(FiscalSerial.channel, (call) async {
          final args = call.arguments as Map;
          switch (call.method) {
            case 'devices':
              return [
                {'id': 'attached', 'label': 'FP21 de probă'},
              ];
            case 'select':
              expect(args['model'], 'tremolFp21');
              return '';
            case 'openCandidate':
              expect(args['id'], 'attached');
              return 4;
            case 'bindCandidate':
            case 'open':
              expect(args['id'], stable);
              return call.method == 'open' ? 4 : null;
            case 'write':
              reply = await _fp21Reply(peer, args['bytes'] as Uint8List);
              return null;
            case 'read':
              final data = Uint8List.fromList(reply);
              reply = [];
              return data;
            case 'close':
              return null;
            default:
              fail('Unexpected local operation ${call.method}');
          }
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(FiscalSerial.channel, null),
        );
        await pumpStillWidget(
          tester,
          const RepaintBoundary(
            key: ValueKey('screen'),
            child: CompanionApp(home: DeviceSetupPage()),
          ),
        );
        await tester.pumpAndSettle();
        final pin = find.byKey(const ValueKey('enrollment-pin'));
        await tester.ensureVisible(pin);
        await tester.enterText(pin, '123');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        if (!existingRegister) await _capture(tester, 'fiscal-pin-entry');
        await _tap(tester, 'Configurează casa');
        // Any prior operational register belongs to its own assignment.
        await _tap(tester, 'Tremol M20');
        await _tap(tester, 'Activa FP21 (Tremol)');
        expect(find.text('Diagnostic USB FP21'), findsNothing);
        expect(find.byTooltip('Ecran client'), findsNothing);
        await _tap(tester, 'Alege casa USB');
        await _tap(tester, 'FP21 de probă');
        await _tap(tester, 'Verifică ECR');
        expect(peer.commands, [0x20, 0x6a]);
        await _tap(tester, 'Salvează conexiunea');
        expect(tester.widget<TextField>(pin).controller!.text, '123');
        expect(await storage.read(key: 'setup_step_v3'), '0');
        expect(await storage.read(key: 'erp_pairing_v1'), isNull);
        expect(await storage.read(key: 'setup_complete_v2'), isNull);
        expect(
          await storage.read(key: 'local_hardware_v1'),
          existingRegister ? active : null,
        );
        final draft =
            jsonDecode((await storage.read(key: 'setup_local_register_v1'))!)
                as Map;
        expect(draft['deviceId'], stable);
        expect(draft['model'], 'tremolFp21');
        expect(draft.keys, isNot(contains('password')));
        expect(draft.keys, isNot(contains('tcpPassword')));
        expect(draft.keys, isNot(contains('vivaEnabled')));
        // A normal ECR wizard opens the staged endpoint only if there is no live assignment.
        await pumpStillWidget(
          tester,
          const CompanionApp(home: DeviceSetupPage(initialStep: 2)),
        );
        await tester.pumpAndSettle();
        if (existingRegister) {
          final host = find.widgetWithText(TextField, 'IP local ECR');
          await tester.scrollUntilVisible(
            host,
            110,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            tester.widget<TextField>(host).controller!.text,
            '192.168.4.3',
          );
        } else {
          await tester.scrollUntilVisible(
            find.text('FP21 de probă'),
            110,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('FP21 de probă'), findsOneWidget);
          await _tap(tester, 'Verifică ECR');
          await _tap(tester, 'Continuă');
          expect(
            jsonDecode(
              (await storage.read(key: 'local_hardware_v1'))!,
            )['deviceId'],
            stable,
          );
          expect(await storage.read(key: 'setup_local_register_v1'), isNull);
        }
        expect(tester.takeException(), isNull);
        await pumpStillWidget(tester, const SizedBox());
      },
    );
  }
}
