import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:chimera_companion/customer_display.dart';
import 'package:chimera_companion/customer_display_page.dart';
import 'package:chimera_companion/local_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'display error offers relevant Android settings and technical reason',
    (tester) async {
      final pages = <String>[];
      var failRead = true;
      const settings = MethodChannel('chimera/settings');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(CustomerDisplay.channel, (call) async {
        if (failRead) throw PlatformException(code: 'unavailable');
        return {
          'state': 'error',
          'errorCode': 'display_rejected',
          'enabled': true,
          'backgroundAllowed': true,
          'displays': [],
        };
      });
      messenger.setMockMethodCallHandler(settings, (call) async {
        pages.add((call.arguments as Map)['page'] as String);
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(settings, null);
        messenger.setMockMethodCallHandler(CustomerDisplay.channel, null);
      });
      await tester.pumpWidget(const MaterialApp(home: CustomerDisplayPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reîncearcă'));
      await tester.pumpAndSettle();
      expect(find.text('Nu pot verifica ecranul clientului.'), findsOneWidget);
      failRead = false;
      await tester.tap(find.text('Reîncearcă'));
      await tester.pumpAndSettle();
      for (final label in ['Setări ecran Android', 'Permisiuni Android']) {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(pages, ['display', 'overlay']);
      await tester.ensureVisible(find.text('Detalii tehnice'));
      await tester.tap(find.text('Detalii tehnice'));
      await tester.pumpAndSettle();
      expect(find.text('Cod: display_rejected'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'compact display settings show missing screen, permission and ready states',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var state = 'no_display';
      var allowed = false;
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CustomerDisplay.channel, (call) async {
            calls.add(call.method);
            return {
              'state': state,
              'enabled': true,
              'backgroundAllowed': allowed,
              'displays': [],
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(CustomerDisplay.channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.dark(), home: const CustomerDisplayPage()),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Niciun ecran secundar'), findsOneWidget);
      state = 'permission_required';
      await tester.tap(find.text('Reverifică ecranul'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Permite afișarea în fundal'));
      await tester.pumpAndSettle();
      expect(calls, contains('permission'));
      state = 'ready';
      allowed = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Permite afișarea în fundal'), findsNothing);
      expect(find.textContaining('așteaptă coșul'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  Map<String, dynamic> basket() => {
    'revision': 1,
    'currency': 'RON',
    'totalMinor': 1000,
    'lines': [
      {'name': 'Cafea', 'quantity': 1.5, 'totalMinor': 1000},
      {'name': 'Apă', 'quantity': 1, 'totalMinor': 0},
    ],
    'customer': 'private',
  };
  test(
    'keeps quoted totals and fractional quantities, strips private fields',
    () {
      final parsed = customerDisplayPayload(basket());
      expect(parsed['totalMinor'], 1000);
      expect((parsed['lines'] as List)[1]['totalMinor'], 0);
      expect((parsed['lines'] as List)[0]['quantity'], 1.5);
      expect(parsed.containsKey('customer'), false);
    },
  );
  test('rejects malformed, oversized and non-finite payloads', () {
    for (final invalid in [
      {...basket(), 'totalMinor': -1},
      {...basket(), 'currency': 'RON<script>'},
      {
        ...basket(),
        'lines': List.filled(101, {
          'name': 'a',
          'quantity': 1,
          'totalMinor': 10,
        }),
      },
      {
        ...basket(),
        'lines': [
          {'name': 'a', 'quantity': double.nan, 'totalMinor': 1},
        ],
      },
      {...basket(), 'lines': []},
    ]) {
      expect(() => customerDisplayPayload(invalid), throwsArgumentError);
    }
  });
  test(
    'customer web settings are bounded, HTTPS-only and strip private fields',
    () {
      final settings = {
        'url': 'https://brand.example/display',
        'title': 'Cafea',
        'message': 'Bine ai venit',
        'accent': '#aabbcc',
        'theme': 'dark',
        'token': 'private',
      };
      final parsed = customerDisplayPayload({
        ...basket(),
        'presentation': settings,
      });
      expect((parsed['presentation'] as Map).containsKey('token'), false);
      for (final url in [
        'http://brand.example',
        'javascript:alert(1)',
        'file:///data/private',
        'https://user:secret@brand.example',
        'https://brand.example/#token',
      ]) {
        expect(
          () => customerDisplayPayload({
            ...basket(),
            'presentation': {...settings, 'url': url},
          }),
          throwsArgumentError,
        );
      }
      expect(
        () => customerDisplayPayload({
          ...basket(),
          'presentation': {...settings, 'accent': 'red;display:none'},
        }),
        throwsArgumentError,
      );
    },
  );
  test(
    'display update requires verified authorization and does not need an ECR',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CustomerDisplay.channel, (call) async {
            calls.add(call);
            return {'state': 'showing', 'enabled': true, 'applied': true};
          });
      final bridge = LocalBridge();
      expect(
        (await bridge.run('customerDisplay', 'no-auth', basket()))['outcome'],
        'rejected',
      );
      expect(calls, isEmpty);
      final result = await bridge.run(
        'customerDisplay',
        'display',
        {...basket(), 'posId': 'verified-pos'},
        authorizationExpires: DateTime.now().add(const Duration(minutes: 1)),
      );
      expect(result['outcome'], 'succeeded');
      expect(calls.single.method, 'update');
      expect((calls.single.arguments as Map).containsKey('customer'), false);
      await bridge.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CustomerDisplay.channel, null);
    },
  );
}
