import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/pairing.dart';
import 'package:chimera_companion/setup_header.dart';
import 'package:chimera_companion/enrollment_service.dart';

class _Enrollment implements EnrollmentService {
  int restores = 0;
  @override
  Future<Map<String, dynamic>?> restore() async {
    restores++;
    return null;
  }

  @override
  Future<Map<String, dynamic>> enroll(Uri origin, String pin) async => {};
}

void main() {
  for (final enterprise in [false, true]) {
    testWidgets(
      'keyboard resize preserves ${enterprise ? 'server address' : 'PIN'} focus and input',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 800);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final service = _Enrollment();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SetupFrame(
                step: 0,
                child: ListView(
                  children: [
                    PairingPage(
                      embedded: true,
                      showScene: false,
                      service: service,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (enterprise) {
          await tester.tap(find.byTooltip('Unde găsesc PIN-ul?'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.text('Ești client Enterprise sau self-hosted?'),
          );
          await tester.pumpAndSettle();
        }
        final field = find.byKey(
          ValueKey(enterprise ? 'enterprise-url' : 'enrollment-pin'),
        );
        await tester.ensureVisible(field);
        await tester.enterText(
          field,
          enterprise ? 'https://firma.example' : '123',
        );
        final editable = find.descendant(
          of: field,
          matching: find.byType(EditableText),
        );
        final before = tester.state<EditableTextState>(editable);
        expect(before.widget.focusNode.hasFocus, isTrue);
        tester.view.viewInsets = const FakeViewPadding(bottom: 400);
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(editable), same(before));
        expect(before.widget.focusNode.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        tester.testTextInput.enterText(
          enterprise ? 'https://firma.example.ro' : '123456',
        );
        await tester.pump();
        expect(
          before.widget.controller.text,
          enterprise ? 'https://firma.example.ro' : '123456',
        );
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(editable), same(before));
        expect(service.restores, 1);
      },
    );
  }
}
