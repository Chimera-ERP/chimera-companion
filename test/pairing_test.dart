import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/pairing.dart';

void main() {
  testWidgets('Pairing uses ERP PIN, without QR or operator login', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: PairingPage()));
    await tester.pumpAndSettle();
    expect(find.text('PIN generat în ERP'), findsOneWidget);
    await tester.tap(find.text('Asociază'));
    await tester.pump();
    expect(
      find.textContaining('Introdu adresa ERP și PIN-ul de 6 cifre.'),
      findsWidgets,
    );
  });
}
