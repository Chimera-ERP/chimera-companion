import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../diagnostic_outbox.dart';
import '../debug_panel.dart';
import 'console_contract.dart';
import 'console_transport.dart';
import 'console_test_menu.dart';
import 'ulanzi_adapter.dart';

/// A single foreground KDS owns the console; this service has no business APIs.
class ConsoleService extends ChangeNotifier {
  ConsoleService({ConsoleTransport? transport, ConsoleAdapter? adapter})
    : transport = transport ?? NativeConsoleTransport() {
    this.adapter = adapter ?? UlanziAdapter(this.transport);
    _subscription = this.adapter.presses.listen(
      _press,
      onError: (Object e) {
        fail(e);
      },
    );
  }
  final ConsoleTransport transport;
  late final ConsoleAdapter adapter;
  late final StreamSubscription<int> _subscription;
  final _events = StreamController<Map<String, Object>>.broadcast();
  Stream<Map<String, Object>> get events => _events.stream;
  String? deviceId, error;
  bool connecting = false, connected = false, leased = false;
  String title = 'Consolă KDS';
  int? lastKey;
  ConsoleFrame? _frame;
  ConsoleTestMenu? _testMenu;
  bool _testDrawing = false;
  bool get testing => _testMenu != null;
  Map<String, Object?> get diagnostics => {
    'connected': connected,
    'leased': leased,
    'mode': testing
        ? 'test'
        : leased
        ? 'kds'
        : 'idle',
    'drawing': _testDrawing,
    'lastKey': lastKey,
    'error': error,
    'adapter': adapter.diagnostics,
  };
  int _generation = 0, _sequence = 0, _revision = 0;
  Timer? _expiry;
  Future<List<Map<String, dynamic>>> devices() => transport.devices();
  Future<void> connect(String id) async {
    await disconnect();
    connecting = true;
    error = null;
    notifyListeners();
    try {
      await adapter.connect(id);
      deviceId = id;
      connected = true;
      await clear();
    } catch (e) {
      fail(e);
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  void fail(Object e) {
    error = e is PlatformException && e.message != null
        ? e.message!
        : 'Consola USB nu răspunde. Verifică alimentarea și conexiunea.';
    debugLog('Consolă KDS: $e');
    unawaited(
      reportCompanionError
          ?.call('kds_console_usb', error!)
          .catchError((Object _) {}),
    );
    connected = false;
    unawaited(adapter.close());
    _frame = null;
    _testMenu = null;
    _testDrawing = false;
    _generation++;
    notifyListeners();
  }

  void _press(int index) {
    if (index < 0 || index >= 13) return;
    lastKey = index + 1;
    notifyListeners();
    if (connected && testing && !leased) {
      if (!_testDrawing) {
        _testMenu!.press(index);
        unawaited(_showTest());
      }
      return;
    }
    if (connected && !leased && index == 0) {
      unawaited(startTest());
      return;
    }
    final frame = _frame;
    if (!connected || !leased || frame == null || index >= frame.keys.length) {
      return;
    }
    final key = frame.keys[index];
    if (!key.enabled) return;
    // One action per acknowledged view, even if the same physical key is tapped again.
    _frame = null;
    _events.add({
      'type': 'press',
      'revision': frame.revision,
      'id': key.id,
      'sequence': ++_sequence,
    });
  }

  Future<void> startTest() async {
    if (!connected || leased || testing) return;
    _testMenu = ConsoleTestMenu();
    _frame = null;
    _expiry?.cancel();
    lastKey = null;
    await _showTest();
  }

  Future<void> _showTest() async {
    final menu = _testMenu;
    if (menu == null || !connected || leased) return;
    final generation = ++_generation;
    _testDrawing = true;
    title = menu.frame.title;
    notifyListeners();
    try {
      await adapter.display(menu.frame);
    } catch (e) {
      if (generation == _generation) fail(e);
    } finally {
      if (generation == _generation) {
        _testDrawing = false;
        notifyListeners();
      }
    }
  }

  Future<void> stopTest() async {
    if (testing) await clear();
  }

  Future<void> show(ConsoleFrame frame) async {
    if (!connected || !leased || frame.revision <= _revision) {
      throw StateError('Stale console frame');
    }
    _revision = frame.revision;
    final generation = ++_generation;
    _frame = null;
    _expiry?.cancel();
    await adapter.display(frame);
    if (generation != _generation || !connected || !leased) return;
    _frame = frame;
    title = frame.title;
    notifyListeners();
    _expiry = Timer(const Duration(seconds: 8), () => unawaited(clear()));
  }

  void acquire() {
    if (leased || !connected || testing) {
      throw StateError('Console unavailable');
    }
    leased = true;
    _revision = 0;
    _sequence = 0;
    notifyListeners();
  }

  Future<void> release() async {
    leased = false;
    await clear();
  }

  Future<void> clear() async {
    _generation++;
    _frame = null;
    _testMenu = null;
    _testDrawing = false;
    _expiry?.cancel();
    title = 'Așteaptă KDS';
    notifyListeners();
    if (connected) {
      try {
        await adapter.display(
          ConsoleFrame(1, 'Așteaptă KDS', [
            ConsoleKey(
              'waiting',
              leased ? 'Așteaptă KDS' : 'Test KDS',
              'open',
              !leased,
            ),
          ]),
        );
      } catch (e) {
        fail(e);
      }
    }
  }

  Future<void> disconnect() async {
    leased = false;
    _generation++;
    _expiry?.cancel();
    _frame = null;
    _testMenu = null;
    _testDrawing = false;
    connected = false;
    deviceId = null;
    await adapter.close();
    notifyListeners();
  }

  Future<void> close() async {
    await disconnect();
    await _subscription.cancel();
    await _events.close();
  }
}
