import 'package:flutter_test/flutter_test.dart';
import 'package:rive/rive.dart' as rive;
import 'package:chimera_companion/companion_scene.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('motion file loads once across concurrent scenes', () async {
    final library = CompanionMotionLibrary();
    final first = library.load();
    expect(library.load(), same(first));
    await first;
    final file = library.file;
    expect(file, isNotNull);
    await library.load();
    expect(library.file, same(file));
    expect(library.failed, isFalse);
    library.dispose();
  });
  test(
    'only selected equipment stays visible throughout the real Rive loop',
    () async {
      await rive.RiveNative.init();
      final file = (await rive.File.asset(
        'assets/motion/companion.riv',
        riveFactory: rive.Factory.flutter,
      ))!;
      final controller = rive.RiveWidgetController(
        file,
        artboardSelector: rive.ArtboardSelector.byName('custom'),
      );
      try {
        for (final selected in [
          <int>{7, 10},
          <int>{3},
          <int>{},
          <int>{2, 3, 6, 7, 9, 10},
        ]) {
          selectCompanionEquipment(controller.artboard, selected);
          for (var frame = 0; frame < 360; frame++) {
            controller.advance(1 / 60);
          }
          for (final id in [2, 3, 6, 7, 9, 10]) {
            final slot = controller.artboard.component('Equipment$id');
            expect(slot, isNotNull);
            expect(slot!.scaleX, selected.contains(id) ? greaterThan(0) : 0);
            expect(slot.scaleY, selected.contains(id) ? greaterThan(0) : 0);
            slot.dispose();
          }
        }
      } finally {
        controller.dispose();
        file.dispose();
      }
    },
  );
  test(
    'bundled Rive scenes import and advance in the actual Flutter runtime',
    () async {
      await rive.RiveNative.init();
      final file = await rive.File.asset(
        'assets/motion/companion.riv',
        riveFactory: rive.Factory.flutter,
      );
      expect(file, isNotNull);
      try {
        for (final scene in CompanionSceneState.values) {
          final controller = rive.RiveWidgetController(
            file!,
            artboardSelector: rive.ArtboardSelector.byName(scene.name),
          );
          try {
            final hub = controller.artboard.component('Companion');
            expect(hub, isNotNull, reason: scene.name);
            controller.advance(0);
            final initialY = hub!.y;
            for (var frame = 0; frame < 120; frame++) {
              controller.advance(1 / 60);
            }
            expect(
              hub.y,
              isNot(closeTo(initialY, 0.1)),
              reason: '${scene.name} must animate',
            );
            for (var frame = 0; frame < 300; frame++) {
              controller.advance(1 / 60);
            }
            final idleY = hub.y;
            for (var frame = 0; frame < 60; frame++) {
              controller.advance(1 / 60);
            }
            expect(
              hub.y,
              isNot(closeTo(idleY, 0.1)),
              reason: '${scene.name} idle must continue after assembly',
            );
            hub.dispose();
          } finally {
            controller.dispose();
          }
        }
      } finally {
        file?.dispose();
      }
    },
  );
}
