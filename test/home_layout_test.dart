import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/connection_status.dart';
import 'package:chimera_companion/main.dart';

void main() {
  testWidgets(
    'connection indicators stack in portrait and align in landscape',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> show(Size size) async {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: ConnectionIndicators(
                states: {'ECR': true, 'POS': false, 'Chimera': null},
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await show(const Size(390, 844));
      expect(find.text('Fără activitate recentă'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('Conexiune indisponibilă'), findsNothing);
      expect(
        tester.getCenter(find.text('Casă de marcat')).dy,
        lessThan(tester.getCenter(find.text('Aplicația POS')).dy),
      );
      expect(
        tester.getCenter(find.text('Aplicația POS')).dy,
        lessThan(tester.getCenter(find.text('Chimera ERP')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Casă de marcat')).dx,
        tester.getTopLeft(find.text('Aplicația POS')).dx,
      );
      await show(const Size(844, 390));
      expect(
        tester.getCenter(find.text('Casă de marcat')).dy,
        tester.getCenter(find.text('Aplicația POS')).dy,
      );
      expect(
        tester.getCenter(find.text('Casă de marcat')).dx,
        lessThan(tester.getCenter(find.text('Aplicația POS')).dx),
      );
      expect(
        tester.getCenter(find.text('Aplicația POS')).dx,
        lessThan(tester.getCenter(find.text('Chimera ERP')).dx),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home has connection rows and opens diagnostics without operational buttons',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: CompanionHome()));
      await tester.pumpAndSettle();
      for (final label in [
        'Asociere ERP',
        'Dispozitive ECR și Viva',
        'Catalog Tremol',
      ]) {
        expect(find.text(label), findsNothing);
      }
      expect(find.text('Raport X'), findsNothing);
      expect(find.text('Închide ziua · Z'), findsNothing);
      expect(find.text('Casa de marcat'), findsOneWidget);
      expect(find.text('Terminal de plată'), findsOneWidget);
      expect(find.text('POS'), findsOneWidget);
      await tester.tap(find.byTooltip('Diagnostic'));
      await tester.pumpAndSettle();
      expect(find.text('Doar probleme'), findsOneWidget);
      expect(find.text('Mesaje conexiune'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
