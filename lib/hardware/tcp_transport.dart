import 'dart:async';
import 'dart:io';
import 'connection.dart';

abstract interface class ByteSession {
  Future<List<int>> exchange(
    List<int> request,
    int? Function(List<int>) frameLength,
  );
  Future<void> close();
}

typedef SessionFactory = Future<ByteSession> Function(LanEndpoint endpoint);

/// One command in flight, bounded buffering and no automatic retry. The caller
/// treats any lost response after dispatch as an unknown hardware outcome.
class TcpByteSession implements ByteSession {
  TcpByteSession._(this._socket, this._replyTimeout) {
    _subscription = _socket.listen(
      (bytes) {
        _buffer.addAll(bytes);
        if (_buffer.length > 65536) {
          _fail(const FormatException('Hardware response too large'));
          return;
        }
        _notify();
      },
      onError: _fail,
      onDone: () => _fail(const SocketException('Hardware disconnected')),
    );
  }
  final Socket _socket;
  final Duration _replyTimeout;
  late final StreamSubscription<List<int>> _subscription;
  final List<int> _buffer = [];
  Completer<List<int>>? _pending;
  int? Function(List<int>)? _length;
  Object? _failure;
  static Future<ByteSession> connect(LanEndpoint endpoint) async =>
      connectWithTimeouts(endpoint);

  static Future<ByteSession> connectWithTimeouts(
    LanEndpoint endpoint, {
    Duration connectTimeout = const Duration(seconds: 5),
    Duration replyTimeout = const Duration(seconds: 15),
  }) async => TcpByteSession._(
    await Socket.connect(endpoint.host, endpoint.port, timeout: connectTimeout),
    replyTimeout,
  );

  void _fail(Object error) {
    _failure = error;
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.completeError(error);
    }
  }

  void _notify() {
    if (_pending == null || _pending!.isCompleted) return;
    try {
      // Datecs SYN announces processing, not a new command or a retry request.
      // Consume it only at a frame boundary; the total exchange deadline remains.
      while (_buffer.isNotEmpty && _buffer.first == 0x16) {
        _buffer.removeAt(0);
      }
      final length = _length!(_buffer);
      if (length != null && _buffer.length >= length) {
        final result = _buffer.sublist(0, length);
        _buffer.removeRange(0, length);
        _pending!.complete(result);
      }
    } catch (error) {
      _fail(error);
    }
  }

  @override
  Future<List<int>> exchange(
    List<int> request,
    int? Function(List<int>) frameLength,
  ) async {
    if (_pending != null) {
      throw StateError('Hardware command already in flight');
    }
    if (_failure != null) throw StateError('Hardware connection is closed');
    if (_buffer.isNotEmpty) {
      throw const FormatException('Unexpected unsolicited hardware data');
    }
    _length = frameLength;
    _pending = Completer<List<int>>();
    try {
      _socket.add(request);
      // Waiting for the response also handles write errors, avoiding unobserved
      // response-future errors when a connection is lost during dispatch.
      return await _pending!.future.timeout(_replyTimeout);
    } catch (error) {
      _failure = error;
      _socket.destroy();
      rethrow;
    } finally {
      _pending = null;
      _length = null;
    }
  }

  @override
  Future<void> close() async {
    _socket.destroy();
    await _subscription.cancel();
  }
}
