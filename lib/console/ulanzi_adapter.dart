import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'console_contract.dart';
import 'console_transport.dart';
import 'console_icons.dart';
import 'ulanzi_protocol.dart';

abstract interface class ConsoleAdapter {
  Stream<int> get presses;
  Map<String, Object?> get diagnostics;
  Future<void> connect(String id);
  Future<void> display(ConsoleFrame frame);
  Future<void> close();
}

class UlanziAdapter implements ConsoleAdapter {
  UlanziAdapter(this.transport, {this.render = renderConsoleKey});
  final ConsoleTransport transport;
  final Future<Uint8List> Function(ConsoleKey) render;
  final _presses = StreamController<int>.broadcast();
  StreamSubscription<Uint8List>? _subscription;
  final _held = <int>{};
  final _lastPress = <int, DateTime>{};
  final _images = <String, Uint8List>{};
  Completer<void>? _ready;
  bool _drawing = false;
  int _epoch = 0;
  Timer? _heartbeat;
  String? _lastScreen;
  Future<void> _queue = Future.value();
  int _reports = 0, _buttons = 0, _uploads = 0;
  int? _lastCommand;
  List<int>? _lastButton;
  String? _lastIgnored;
  @override
  Map<String, Object?> get diagnostics => {
    'reports': _reports,
    'buttonReports': _buttons,
    'uploads': _uploads,
    'drawing': _drawing,
    'lastReportType': _lastCommand?.toRadixString(16),
    'lastButton': _lastButton,
    'lastIgnored': _lastIgnored,
  };
  @override
  Stream<int> get presses => _presses.stream;
  @override
  Future<void> connect(String id) async {
    await close();
    _reports = _buttons = _uploads = 0;
    _lastCommand = null;
    _lastButton = null;
    _lastIgnored = null;
    _subscription = transport.reports.listen(
      (bytes) {
        final command = UlanziProtocol.command(bytes);
        _reports++;
        _lastCommand = command;
        if ([0x101, 0x102].contains(command) && bytes.length >= 12) {
          _buttons++;
          _lastButton = bytes.sublist(8, 12);
        }
        if (command == 0x303 && _ready?.isCompleted == false) {
          try {
            final info = jsonDecode(
              utf8.decode(bytes.skip(8).takeWhile((b) => b != 0).toList()),
            );
            if (info is! Map || ![0, '0'].contains(info['error'])) {
              throw const FormatException('Ulanzi firmware not ready');
            }
            _ready!.complete();
          } catch (e) {
            _ready!.completeError(e);
          }
        }
        if (command == 0x010b && !_drawing) {
          _lastScreen = null;
        }
        final button = UlanziProtocol.button(bytes);
        if (button == null) return;
        if (!button.pressed) {
          _held.remove(button.index);
          return;
        }
        if (!_held.add(button.index)) {
          _lastIgnored = 'held';
          return;
        }
        if (_drawing) {
          _lastIgnored = 'drawing';
          return;
        }
        final now = DateTime.now(), last = _lastPress[button.index];
        if (last != null && now.difference(last).inMilliseconds < 250) {
          _lastIgnored = 'debounce';
          return;
        }
        _lastIgnored = null;
        _lastPress[button.index] = now;
        _presses.add(button.index);
      },
      onError: (Object error, StackTrace stack) {
        _presses.addError(error, stack);
      },
    );
    try {
      await transport.open(id);
      await _barrier();
      _heartbeat = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_drawing || _ready != null) return;
        final now = DateTime.now();
        final time = [
          now.hour,
          now.minute,
          now.second,
        ].map((n) => n.toString().padLeft(2, '0')).join(':');
        final next = _queue.then(
          (_) => transport.write(
            UlanziProtocol.packets(6, utf8.encode('1|0|0|$time|0')),
          ),
        );
        _queue = next.catchError((Object error) {
          _presses.addError(error);
        });
      });
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> _barrier() async {
    final ready = Completer<void>();
    _ready = ready;
    await transport.write(UlanziProtocol.packets(3, []));
    try {
      await ready.future.timeout(const Duration(seconds: 4));
    } finally {
      if (_ready == ready) _ready = null;
    }
  }

  @override
  Future<void> display(ConsoleFrame frame) {
    final epoch = _epoch;
    final next = _queue.then((_) async {
      if (epoch != _epoch) throw StateError('USB connection changed');
      final fingerprint = jsonEncode(
        frame.keys.map((k) => [k.label, k.icon, k.enabled]).toList(),
      );
      if (fingerprint == _lastScreen) return;
      _drawing = true;
      try {
        final images = <int, Uint8List>{};
        for (var i = 0; i < 13; i++) {
          final key = i < frame.keys.length
              ? frame.keys[i]
              : const ConsoleKey('empty', '', 'open', false);
          final cache = jsonEncode([key.label, key.icon, key.enabled]);
          if (_images.length > 128) _images.clear();
          images[i] = _images[cache] ??= await render(key);
        }
        await _barrier();
        await transport.write(
          UlanziProtocol.packets(1, UlanziProtocol.screen(images)),
        );
        await _barrier();
        _lastScreen = fingerprint;
        _uploads++;
      } finally {
        _drawing = false;
      }
    });
    _queue = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> close() async {
    _epoch++;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _subscription?.cancel();
    _subscription = null;
    await transport.close();
    _lastScreen = null;
    _held.clear();
    _lastPress.clear();
  }
}
