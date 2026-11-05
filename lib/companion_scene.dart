import 'package:flutter/material.dart';
import 'package:rive/rive.dart' as rive;

enum CompanionSceneState {
  splash,
  fiscal,
  payment,
  scale,
  printer,
  display,
  keyboard,
  welcome,
  front,
  back,
  custom,
  connecting,
  ready,
  attention,
}

/// Controls decorative playback without pausing navigation or operation timers.
class CompanionScenePlayback extends InheritedWidget {
  const CompanionScenePlayback({
    super.key,
    required this.enabled,
    required super.child,
  });
  final bool enabled;
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CompanionScenePlayback>()
          ?.enabled ??
      true;
  @override
  bool updateShouldNotify(CompanionScenePlayback oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Decoded once for this app tree; every scene owns only its artboard instance.
class CompanionMotionLibrary extends ChangeNotifier {
  rive.File? file;
  bool failed = false;
  bool _disposed = false;
  Future<void>? _loading;
  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    rive.File? loaded;
    try {
      await rive.RiveNative.init();
      loaded = await rive.File.asset(
        'assets/motion/companion.riv',
        riveFactory: rive.Factory.flutter,
      );
    } catch (_) {
      // Decoration must not block enrollment or recovery.
    }
    if (_disposed) {
      loaded?.dispose();
      return;
    }
    file = loaded;
    failed = loaded == null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    file?.dispose();
    super.dispose();
  }
}

class CompanionMotionScope extends StatefulWidget {
  const CompanionMotionScope({super.key, required this.child});
  final Widget child;
  @override
  State<CompanionMotionScope> createState() => _CompanionMotionScopeState();
}

class _CompanionMotionScopeState extends State<CompanionMotionScope> {
  final library = CompanionMotionLibrary();
  @override
  void dispose() {
    library.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _MotionLibrary(library: library, child: widget.child);
}

class _MotionLibrary extends InheritedWidget {
  const _MotionLibrary({required this.library, required super.child});
  final CompanionMotionLibrary library;
  @override
  bool updateShouldNotify(_MotionLibrary oldWidget) =>
      library != oldWidget.library;
}

/// Selection modifies wrapper transforms, never the mechanical animation itself.
/// Wrappers have no timeline keys, so unchecked equipment stays hidden in motion.
void selectCompanionEquipment(rive.Artboard artboard, Set<int> equipment) {
  const supported = [2, 3, 6, 7, 9, 10];
  final visible = supported.where(equipment.contains).toList();
  final columns = visible.length <= 3 ? visible.length : 3;
  final scale = switch (visible.length) {
    1 => 0.9,
    2 => 0.6,
    3 => 0.45,
    _ => 0.38,
  };
  final spacing = columns == 2 ? 300.0 : 200.0;
  for (final id in supported) {
    final slot = artboard.component('Equipment$id');
    if (slot == null) continue;
    try {
      final index = visible.indexOf(id);
      final shown = index >= 0;
      slot.scaleX = slot.scaleY = shown ? scale : 0;
      if (shown) {
        final row = index ~/ columns;
        final rowCount = (visible.length - row * columns).clamp(0, columns);
        slot.x = (index % columns - (rowCount - 1) / 2) * spacing;
        slot.y = visible.length > 3 ? (row == 0 ? -80 : 80) : 0;
      }
    } finally {
      slot.dispose();
    }
  }
}

/// Decorative only. Actual operation state remains owned by its service.
class CompanionScene extends StatefulWidget {
  const CompanionScene({
    super.key,
    this.scene = CompanionSceneState.welcome,
    this.height,
    this.equipment,
  });
  final CompanionSceneState scene;
  final double? height;
  final Set<int>? equipment;
  @override
  State<CompanionScene> createState() => _CompanionSceneState();
}

class _CompanionSceneState extends State<CompanionScene>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  CompanionMotionLibrary? _library;
  bool _ownsLibrary = false;
  bool _active = true;
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_library == null && CompanionScenePlayback.of(context)) {
      _library = context
          .dependOnInheritedWidgetOfExactType<_MotionLibrary>()
          ?.library;
      _ownsLibrary = _library == null;
      _library ??= CompanionMotionLibrary();
      _library!.addListener(_loaded);
      _library!.load();
    }
  }

  void _loaded() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) setState(() => _active = state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _library?.removeListener(_loaded);
    if (_ownsLibrary) _library?.dispose();
    super.dispose();
  }

  Widget _still() {
    if (widget.scene == CompanionSceneState.custom &&
        widget.equipment != null) {
      const scenes = {
        2: 'fiscal',
        3: 'payment',
        6: 'scale',
        7: 'printer',
        9: 'display',
        10: 'keyboard',
      };
      return Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          children: [
            for (final id in scenes.keys.where(widget.equipment!.contains))
              SizedBox(
                width: 100,
                height: 84,
                child: Image.asset('assets/motion/${scenes[id]}.png'),
              ),
          ],
        ),
      );
    }
    return Image.asset(
      'assets/motion/${widget.scene.name}.png',
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.hub_outlined, size: 64, color: Color(0xff60a5fa)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final file = _library?.file;
    final enabled = CompanionScenePlayback.of(context);
    return ExcludeSemantics(
      child: IgnorePointer(
        child: SizedBox(
          width: double.infinity,
          height:
              widget.height ??
              (MediaQuery.sizeOf(context).height < 500 ? 100 : 210),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: ColoredBox(
              color: const Color(0xff000000),
              child: file == null
                  ? (!enabled || _library?.failed == true
                        ? _still()
                        : const SizedBox.expand())
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: _SceneArtwork(
                        key: ValueKey(widget.scene),
                        file: file,
                        scene: widget.scene,
                        equipment: widget.equipment,
                        active:
                            enabled &&
                            _active &&
                            TickerMode.valuesOf(context).enabled,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SceneArtwork extends StatefulWidget {
  const _SceneArtwork({
    super.key,
    required this.file,
    required this.scene,
    required this.active,
    this.equipment,
  });
  final rive.File file;
  final CompanionSceneState scene;
  final bool active;
  final Set<int>? equipment;
  @override
  State<_SceneArtwork> createState() => _SceneArtworkState();
}

class _SceneArtworkState extends State<_SceneArtwork> {
  late final controller = rive.RiveWidgetController(
    widget.file,
    artboardSelector: rive.ArtboardSelector.byName(widget.scene.name),
  );
  @override
  void initState() {
    super.initState();
    _update();
  }

  void _update() {
    controller.active = widget.active;
    if (widget.scene == CompanionSceneState.custom) {
      selectCompanionEquipment(
        controller.artboard,
        widget.equipment ?? {2, 3, 6, 7, 9, 10},
      );
      controller.scheduleRepaint();
    }
  }

  @override
  void didUpdateWidget(_SceneArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      rive.RiveWidget(controller: controller, fit: rive.Fit.contain);
}
