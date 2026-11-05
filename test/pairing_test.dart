import 'support/still_widget.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/pairing.dart';
import 'package:chimera_companion/enrollment.dart';
import 'package:chimera_companion/enrollment_service.dart';

class EnrollmentFixture implements EnrollmentService {
  Object? failure;
  Map<String, dynamic>? saved;
  Completer<Map<String, dynamic>>? pending;
  final calls = <(Uri, String)>[];
  @override
  Future<Map<String, dynamic>?> restore() async => saved;
  @override
  Future<Map<String, dynamic>> enroll(Uri origin, String pin) async {
    calls.add((origin, pin));
    if (failure != null) throw failure!;
    if (pending != null) return pending!.future;
    return {'location_name': 'Locație de test'};
  }
}

void main() {
  test(
    'cloud enrollment and renewal use Auth while business traffic retains its ERP',
    () {
      final cloud = Uri.parse(defaultEnrollmentOrigin);
      expect(
        enrollmentEndpoint(cloud).toString(),
        'https://auth.chimeraerp.ro/auth/enroll-device',
      );
      expect(() => enrolledErpAddress({}, cloud), throwsFormatException);
      final pairing = {
        'erp_url': 'https://erp.customer.example',
        'auth_url': 'https://auth.chimeraerp.ro',
      };
      final erp = enrolledErpAddress(pairing, cloud);
      expect(erp.origin, 'https://erp.customer.example');
      expect(
        enrolledAuthAddress(
          pairing,
          erp,
        ).resolve('/auth/device-token').toString(),
        'https://auth.chimeraerp.ro/auth/device-token',
      );
      expect(enrolledAuthAddress({}, erp), erp);
      expect(
        enrolledAuthAddress({
          'auth_url': 'https://auth.enterprise.example',
        }, erp).origin,
        'https://auth.enterprise.example',
      );
      for (final invalid in [
        'http://auth.example',
        'https://user@auth.example',
        'https://auth.example/path',
        42,
      ]) {
        expect(
          () => enrolledAuthAddress({'auth_url': invalid}, erp),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'cloud PIN stores the tenant ERP and self-hosted enrollment retains its origin',
    () {
      final cloud = Uri.parse(defaultEnrollmentOrigin);
      expect(
        enrolledErpAddress({
          'erp_url': 'https://erp.cakeexpert.chimeraerp.ro',
        }, cloud).host,
        'erp.cakeexpert.chimeraerp.ro',
      );
      expect(
        enrolledErpAddress({}, Uri.parse('https://self.example.test')).host,
        'self.example.test',
      );
      for (final invalid in [
        'http://erp.example.test',
        'https://user@erp.example.test',
        'https://erp.example.test/path',
        'https://erp.example.test?token=secret',
        42,
      ]) {
        expect(
          () => enrolledErpAddress({'erp_url': invalid}, cloud),
          throwsFormatException,
        );
      }
    },
  );

  Future<void> open(WidgetTester tester, EnrollmentFixture service) async {
    await pumpStillWidget(
      tester,
      MaterialApp(home: PairingPage(service: service)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('enrollment-pin')),
      '123456',
    );
    await tester.ensureVisible(find.text('Conectează'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conectează'));
    await tester.pumpAndSettle();
  }

  testWidgets('PIN first submits only to default HTTPS origin', (tester) async {
    final service = EnrollmentFixture();
    await open(tester, service);
    expect(find.byKey(const ValueKey('enterprise-url')), findsNothing);
    expect(find.text('Chimera Cloud'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.text('chimeraerp.ro'), findsNothing);
    await tester.tap(find.text('Conectează'));
    await tester.pumpAndSettle();
    expect(find.text('Introdu PIN-ul de 6 cifre.'), findsOneWidget);
    expect(service.calls, isEmpty);
    await submit(tester);
    expect(service.calls, [(Uri.parse(defaultEnrollmentOrigin), '123456')]);
    expect(find.text('Continuă'), findsOneWidget);
  });
  testWidgets(
    'Enterprise help is available before a rejected PIN and clears the PIN on host change',
    (tester) async {
      final service = EnrollmentFixture();
      await open(tester, service);
      await tester.enterText(
        find.byKey(const ValueKey('enrollment-pin')),
        '123456',
      );
      await tester.tap(find.byTooltip('Unde găsesc PIN-ul?'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Administrare → Dispozitive → Companion-uri'),
        findsOneWidget,
      );
      await tester.tap(find.text('Ești client Enterprise sau self-hosted?'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('enrollment-pin')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const ValueKey('enterprise-url')),
        'https://enterprise.example.test',
      );
      await submit(tester);
      expect(service.calls.single.$1.origin, 'https://enterprise.example.test');
    },
  );
  testWidgets(
    'only three explicit PIN refusals reveal the Enterprise shortcut',
    (tester) async {
      final service = EnrollmentFixture()
        ..failure = TimeoutException('fixture');
      await open(tester, service);
      for (var i = 0; i < 3; i++) {
        await submit(tester);
      }
      expect(
        find.text('Ești client Enterprise sau self-hosted?'),
        findsNothing,
      );
      service.failure = const EnrollmentRejected(400, 'PIN invalid');
      for (var i = 0; i < 2; i++) {
        await submit(tester);
      }
      expect(
        find.text('Ești client Enterprise sau self-hosted?'),
        findsNothing,
      );
      await submit(tester);
      expect(
        find.text('Ești client Enterprise sau self-hosted?'),
        findsOneWidget,
      );
      expect(
        service.calls.every(
          (call) => call.$1.origin == defaultEnrollmentOrigin,
        ),
        isTrue,
      );
    },
  );
  testWidgets(
    'submission stays single-flight, failure requires an explicit retry',
    (tester) async {
      final service = EnrollmentFixture()..pending = Completer();
      await open(tester, service);
      await submit(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(service.calls, hasLength(1));
      service.pending!.completeError(TimeoutException('fixture'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));
      expect(service.calls, hasLength(1));
      expect(find.text('Conectează'), findsOneWidget);
    },
  );
  testWidgets(
    'saved Enterprise association is restored without another enrollment',
    (tester) async {
      final service = EnrollmentFixture()
        ..saved = {
          'erp_url': 'https://enterprise.example.test',
          'location_name': 'Test',
        };
      await open(tester, service);
      expect(find.text('Continuă'), findsOneWidget);
      expect(service.calls, isEmpty);
      await tester.tap(find.text('Schimbă asocierea'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('enterprise-url')))
            .controller!
            .text,
        'https://enterprise.example.test',
      );
    },
  );
}
