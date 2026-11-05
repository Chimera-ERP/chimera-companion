import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/tls_setup.dart';
import 'package:chimera_companion/setup_header.dart';
import 'support/still_widget.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'automatic setup is single-flight and completes only after provisioning succeeds',
    (tester) async {
      final configured = Completer<void>();
      var detections = 0, requests = 0, completed = 0;
      final action = ValueNotifier<SetupAction?>(null);
      await pumpStillWidget(
        tester,
        MaterialApp(
          home: Scaffold(
            body: TlsSetup(
              action: action,
              detectAddress: () async {
                detections++;
                return (name: 'wifi', ip: '192.168.1.10');
              },
              configureConnection: (ip, interface) async {
                expect(ip, '192.168.1.10');
                expect(interface, 'wifi');
                requests++;
                await configured.future;
              },
              onCompleted: () {
                completed++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(action.value!.busy, isTrue);
      expect(action.value!.run, isNull);
      expect(completed, 0);
      expect(find.textContaining('192.168.'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(detections, 1);
      expect(requests, 1);
      configured.complete();
      await tester.pumpAndSettle();
      expect(completed, 1);
      await pumpStillWidget(tester, const SizedBox());
      action.dispose();
    },
  );
  testWidgets(
    'failure keeps details in Advanced and explicit retry redetects the network',
    (tester) async {
      var requests = 0, detections = 0, completed = 0;
      await pumpStillWidget(
        tester,
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TlsSetup(
                detectAddress: () async {
                  detections++;
                  return (name: 'wifi', ip: '192.168.1.10');
                },
                configureConnection: (_, _) async {
                  requests++;
                  throw const FormatException('fixture certificate diagnostic');
                },
                onCompleted: () {
                  completed++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('fixture certificate diagnostic'), findsNothing);
      expect(completed, 0);
      await tester.tap(find.text('Avansat'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('fixture certificate diagnostic'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextField, 'IP LAN al Companion-ului'),
        findsOneWidget,
      );
      await tester.tap(find.text('Certificat administrat manual'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Cheia privată este generată aici'),
        findsNothing,
      );
      expect(find.textContaining('Proxy-ul trebuie să valideze'), findsNothing);
      await tester.ensureVisible(find.byTooltip('Despre certificatul manual'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Despre certificatul manual'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Cheia privată este generată aici'),
        findsOneWidget,
      );
      await tester.tap(find.text('Am înțeles'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Certificat administrat manual'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Certificat administrat manual'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Închide'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Reîncearcă'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reîncearcă'));
      await tester.pumpAndSettle();
      expect(detections, 2);
      expect(requests, 2);
      expect(completed, 0);
      await pumpStillWidget(tester, const SizedBox());
    },
  );
}
