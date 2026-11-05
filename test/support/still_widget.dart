import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/companion_scene.dart';

/// Form/navigation tests don't wait for decorative loops to settle.
/// The actual Rive file and its timelines are exercised in companion_scene_test.
Future<void> pumpStillWidget(WidgetTester tester, Widget widget) =>
    tester.pumpWidget(CompanionScenePlayback(enabled: false, child: widget));
