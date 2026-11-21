import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'connection.dart';
import 'datecs_gateway_protocol.dart';
import 'tcp_transport.dart';
import 'tremol_protocol.dart';

/// Opens the selected transport once. Commands stay on this handle through close.
class FiscalByteSession implements ByteSession {
  FiscalByteSession._(this._handle, this._timeout);

  static const _channel = MethodChannel('chimera/fiscal-serial');
  final int _handle;
  final Duration _timeout;
  final List<int> _buffer = [];
  bool _busy = false;
  bool _closed = false;

  static Future<ByteSession> connect(FiscalEndpoint endpoint) =>
      connectWithTimeouts(endpoint);

  static Future<ByteSession> connectWithTimeouts(
    FiscalEndpoint endpoint, {
    Duration connectTimeout = const Duration(seconds: 5),
    Duration replyTimeout = const Duration(seconds: 15),
  }) async {
    if (endpoint is LanEndpoint) {
      return TcpByteSession.connectWithTimeouts(
        endpoint,
        connectTimeout: connectTimeout,
        replyTimeout: replyTimeout,
      );
    }
    final target = endpoint as FiscalSerialEndpoint;
    final args = {
      'transport': target.transport,
      'id': target.deviceId,
      'baudRate': target.baudRate,
    };
    final handle = await _channel.invokeMethod<int>('open', args);
    if (handle == null) throw StateError('Casa serială a fost deconectată.');
    final session = FiscalByteSession._(handle, replyTimeout);
    if (target.transport == 'bluetooth') return session;
    // Serial adapters may have no descriptor, or share one across units.
    // Work proceeds only on the same handle on which the register identified itself.
    try {
      if (target.model == null ||
          await session._identity(target.model!, target.key) !=
              target.deviceId) {
        throw StateError('Casa conectată prin USB are alt număr de serie.');
      }
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  /// Used only after an explicit foreground selection and Android USB grant.
  static Future<String> bindUsb(
    String attachment, {
    required FiscalModel model,
    required int baudRate,
    bool legacyDatecs = false,
  }) async {
    if (legacyDatecs) {
      if (model != FiscalModel.datecsDp25) {
        throw ArgumentError('Invalid Datecs model');
      }
      final identity = await _channel.invokeMethod<String>('legacyBind', {
        'id': attachment,
        'baudRate': baudRate,
      });
      if (identity == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(identity)) {
        throw const FormatException(
          'Seria casei Datecs nu a putut fi verificată.',
        );
      }
      return identity;
    }
    final handle = await _channel.invokeMethod<int>('openCandidate', {
      'id': attachment,
      'baudRate': baudRate,
    });
    if (handle == null) throw StateError('Casa USB a fost deconectată.');
    final session = FiscalByteSession._(handle, const Duration(seconds: 4));
    try {
      final identity = await session._identity(model, 'usb-selection');
      await _channel.invokeMethod<void>('bindCandidate', {
        'session': handle,
        'id': identity,
      });
      return identity;
    } finally {
      await session.close();
    }
  }

  Future<String> _identity(FiscalModel model, String sequenceKey) async {
    late final String serial;
    if (model == FiscalModel.datecsDp25) {
      final sequence = DatecsGatewayProtocol.nextSequence(sequenceKey);
      const command = 123;
      final response = await exchange(
        DatecsGatewayProtocol.encode(command, '1\t', sequence: sequence),
        DatecsGatewayProtocol.frameLength,
      );
      final fields = DatecsGatewayProtocol.decode(
        response,
        sequence: sequence,
        command: command,
      );
      if (fields.length < 3) {
        throw const FormatException('Serie Datecs indisponibilă.');
      }
      serial = fields[1].trim();
      if (!RegExp(r'^[A-Za-z0-9-]{4,32}$').hasMatch(serial) ||
          RegExp(r'^0+$').hasMatch(serial)) {
        throw const FormatException(
          'Casa Datecs nu a furnizat o serie utilizabilă.',
        );
      }
    } else {
      final sequence = TremolProtocol.nextSerialSequence(sequenceKey);
      const command = 0x60;
      final ready = (await exchange([
        9,
      ], (bytes) => bytes.isEmpty ? null : 1)).single;
      if ((ready & 0xf0) != 0x40 || (ready & 1) != 0) {
        throw StateError(
          'Casa trebuie să fie disponibilă pentru citirea seriei.',
        );
      }
      final reply = await exchange(
        TremolProtocol.encode(sequence, command, []),
        TremolProtocol.frameLength,
      );
      final frame = TremolProtocol.decode(
        reply,
        sequence: sequence,
        command: command,
      );
      if (frame.isAck) {
        throw const FormatException(
          'Citirea seriei de fabricație Tremol nu a fost confirmată.',
        );
      }
      serial = TremolProtocol.manufacturingNumber(model, frame.data);
    }
    return sha256
        .convert(utf8.encode('fiscal/${model.name}/$serial'))
        .toString();
  }

  @override
  Future<List<int>> exchange(
    List<int> request,
    int? Function(List<int>) frameLength,
  ) async {
    if (_closed || _busy) throw StateError('Sesiune serială indisponibilă.');
    _busy = true;
    final elapsed = Stopwatch()..start();
    int remaining() {
      final ms = (_timeout - elapsed.elapsed).inMilliseconds;
      if (ms <= 0) {
        throw TimeoutException('Casa nu a răspuns în timpul permis.');
      }
      return ms;
    }

    try {
      if (request.isNotEmpty) {
        if (_buffer.isNotEmpty) {
          throw const FormatException('Unexpected unsolicited hardware data');
        }
        await _channel.invokeMethod<void>('write', {
          'session': _handle,
          'bytes': Uint8List.fromList(request),
          'timeoutMs': remaining(),
        });
      }
      while (true) {
        while (_buffer.isNotEmpty && _buffer.first == 0x16) {
          _buffer.removeAt(0); // Datecs SYN: still processing the same command.
        }
        final length = frameLength(_buffer);
        if (length != null && length > 0 && _buffer.length >= length) {
          final result = _buffer.sublist(0, length);
          _buffer.removeRange(0, length);
          return result;
        }
        final chunk = await _channel.invokeMethod<Uint8List>('read', {
          'session': _handle,
          'timeoutMs': remaining(),
        });
        if (chunk == null) throw StateError('Casa a întrerupt conexiunea.');
        // FTDI can return a modem status packet with no protocol bytes.
        _buffer.addAll(chunk);
        if (_buffer.length > 65536) {
          throw const FormatException('Hardware response too large');
        }
      }
    } catch (_) {
      await close();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.invokeMethod<void>('close', {'session': _handle});
  }
}
