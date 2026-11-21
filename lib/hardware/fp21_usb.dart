import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'command_journal.dart';
import 'fp21_test_receipt.dart';

import 'contracts.dart';
import 'tcp_transport.dart';
import 'tremol_adapter.dart';

class Fp21UsbDevice {
  const Fp21UsbDevice({required this.id, required this.label});
  final String id;
  final String label;
}

/// Local FP21 diagnostics. Each explicit operation owns its USB handle.
class Fp21Usb {
  const Fp21Usb({this.journal});
  final CommandJournal? journal;
  static const channel = MethodChannel('chimera/fp21-usb');

  Future<List<Fp21UsbDevice>> devices() async {
    final rows = await channel.invokeListMethod<Object?>('devices');
    return [
      for (final row in rows ?? [])
        if (row case {'id': final String id, 'label': final String label})
          Fp21UsbDevice(id: id, label: label),
    ];
  }

  Future<CommandJournal> _commandJournal() async =>
      journal ??
      CommandJournal(
        File(
          '${(await getApplicationSupportDirectory()).path}/hardware-commands.jsonl',
        ),
      );

  // Existing journals stored the original text-only footer in the sample hash.
  static const _legacyFooter = [
    'CHIMERA FIDELITY',
    'Spatiu rezervat pentru codul QR',
    '         +------------+',
    '         |            |',
    '         |            |',
    '         |            |',
    '         |            |',
    '         |            |',
    '         +------------+',
    'https://fidelity.chimeraerp.ro',
    'SFARSIT BON NEFISCAL DE TEST',
  ];

  static Map<String, Object?> _samplePayload(
    int operatorNumber, {
    bool legacy = false,
  }) => {
    'lines': fp21TestReceiptLines,
    'ean13': fp21TestReceiptBarcode,
    if (!legacy) 'qrUrl': fp21TestReceiptQrUrl,
    'footer': legacy ? _legacyFooter : fp21TestReceiptFooter,
    'operatorNumber': operatorNumber,
  };

  static bool _matchesInterruptedSample(
    String deviceId,
    Map<String, dynamic>? row, {
    bool legacyOnly = false,
  }) {
    if (row == null ||
        row['deviceId'] != deviceId ||
        row['operation'] != 'nonFiscal' ||
        row['outcome'] != 'unknown' ||
        row['at'] is! String ||
        row['id'] is! String ||
        !RegExp(r'^usb-test-[0-9]+-[0-9]+$').hasMatch(row['id'] as String)) {
      return false;
    }
    final time = DateTime.tryParse(row['at'] as String);
    if (time == null) return false;
    final age = DateTime.now().toUtc().difference(time);
    if (age.isNegative || age > const Duration(hours: 6)) return false;
    for (var operator = 1; operator <= 20; operator++) {
      for (final legacy in [true, if (!legacyOnly) false]) {
        if (row['hash'] ==
            CommandJournal.fingerprint(
              deviceId,
              'nonFiscal',
              _samplePayload(operator, legacy: legacy),
            )) {
          return true;
        }
      }
    }
    return false;
  }

  static String? _closableTest(
    String deviceId,
    List<Map<String, dynamic>> history,
  ) {
    if (history.isEmpty) return null;
    final latest = history.first;
    if (_matchesInterruptedSample(deviceId, latest)) {
      return latest['id'] as String;
    }
    if (history.length < 2 ||
        latest['operation'] != 'finishNonFiscalTest' ||
        !const {
          'unknown',
          'in_flight',
          'rejected',
        }.contains(latest['outcome'])) {
      return null;
    }
    final original = history[1];
    if (!_matchesInterruptedSample(deviceId, original)) return null;
    final id = original['id'] as String;
    final originalTime = DateTime.parse(original['at'] as String);
    final finishTime = DateTime.tryParse(
      latest['at'] is String ? latest['at'] as String : '',
    );
    if (finishTime == null ||
        finishTime.isBefore(originalTime) ||
        finishTime.isAfter(DateTime.now()) ||
        latest['id'] != 'fp21-finish-$id' ||
        latest['hash'] !=
            CommandJournal.fingerprint(deviceId, 'finishNonFiscalTest', {
              'originalCommandId': id,
            })) {
      return null;
    }
    return id;
  }

  // An explicit A2 (display missing, command illegal) is distinct from a
  // timeout. A fresh physical display attachment can make that close possible.
  static String? _displayRefusedClose(
    String deviceId,
    List<Map<String, dynamic>> history,
  ) {
    if (history.length < 2) return null;
    final prior = _closableTest(deviceId, history.sublist(1));
    final last = history.first;
    if (prior == null ||
        last['id'] != 'fp21-close-$prior' ||
        last['operation'] != 'closeNonFiscalTest' ||
        last['outcome'] != 'unknown' ||
        last['message'] !=
            'Închidere neconfirmată de FP21 (cod A2). Verifică starea imprimantei.' ||
        last['hash'] !=
            CommandJournal.fingerprint(deviceId, 'closeNonFiscalTest', {
              'originalCommandId': prior,
            })) {
      return null;
    }
    return prior;
  }

  Future<_Fp21UsbSession> _open(String id, {String? purpose}) async {
    final handle = await channel.invokeMethod<int>('open', {
      'id': id,
      'purpose': ?purpose,
    });
    if (handle == null) throw StateError('Portul USB nu s-a deschis.');
    return _Fp21UsbSession(handle);
  }

  Future<DeviceStatus> probe(String deviceId) async {
    final session = await _open(deviceId);
    try {
      final status = await readFp21Status(session, includeFirmware: true);
      if (status.details['canFinishNonFiscal'] != true) return status;
      final journalDevice = 'fp21-usb:$deviceId';
      final history = await (await _commandJournal()).latestDeviceCommands(
        journalDevice,
      );
      final refusedId = _displayRefusedClose(journalDevice, history);
      if (refusedId != null) {
        final displayConnected =
            status.details['externalDisplayMissing'] == false;
        return DeviceStatus(
          ready: false,
          description: displayConnected
              ? 'Document nefiscal deschis. Afișajul client este conectat. Poți relua închiderea.'
              : 'Document nefiscal deschis. FP21 a refuzat închiderea (A2) și semnalează că lipsește afișajul client.',
          details: {
            ...status.details,
            if (displayConnected) 'canCloseTestId': refusedId,
          },
        );
      }
      final closableId = _closableTest(journalDevice, history);
      if (closableId == null) return status;
      final row = history.first;
      if (row['id'] != closableId) {
        return DeviceStatus(
          ready: status.ready,
          description:
              '${status.description} Ultima încercare de continuare a bonului nu a fost confirmată.',
          details: {...status.details, 'canCloseTestId': closableId},
        );
      }
      if (!_matchesInterruptedSample(journalDevice, row, legacyOnly: true)) {
        return DeviceStatus(
          ready: false,
          description:
              '${status.description} Tipărirea codurilor nu a fost confirmată. Poți închide bonul.',
          details: {...status.details, 'canCloseTestId': closableId},
        );
      }
      // Only project a protocol error code parsed from the adapter's own message.
      final refusal = RegExp(
        r'^Tipărire întreruptă \(cod ([0-9]{2})\)\.',
      ).firstMatch(row['message'] is String ? row['message'] as String : '');
      final error = refusal == null
          ? 'Ultimul bon de test trimis prin USB a rămas neconfirmat.'
          : 'Imprimanta a întrerupt ultimul bon de test cu codul ${refusal.group(1)}.';
      return DeviceStatus(
        ready: status.ready,
        description: '${status.description} $error',
        details: {
          ...status.details,
          'interruptedTestId': row['id'],
          'canCloseTestId': closableId,
          'interruptedTestError': error,
        },
      );
    } finally {
      await session.close();
    }
  }

  Future<HardwareResult> printTest(
    String deviceId, {
    required int operatorNumber,
    required String operatorPassword,
    required String commandId,
  }) async {
    final log = await _commandJournal();
    return log.execute(
      id: commandId,
      deviceId: 'fp21-usb:$deviceId',
      operation: 'nonFiscal',
      payload: _samplePayload(operatorNumber),
      dispatch: () async {
        late final _Fp21UsbSession session;
        try {
          session = await _open(deviceId, purpose: 'nonFiscalTest');
        } catch (_) {
          return const HardwareResult(
            CommandOutcome.rejected,
            message:
                'Portul USB nu s-a deschis. Verifică imprimanta și permisiunea USB.',
          );
        }
        try {
          return await printFp21TestReceipt(
            session,
            operatorNumber: operatorNumber,
            operatorPassword: operatorPassword,
          );
        } on ArgumentError {
          return const HardwareResult(
            CommandOutcome.rejected,
            message: 'Verifică numărul și parola operatorului.',
          );
        } finally {
          // A detach during release cannot undo a confirmed document close.
          try {
            await session.close();
          } on PlatformException {
            /* handle detached */
          }
        }
      },
    );
  }

  Future<HardwareResult> forceCloseNonFiscal(
    String deviceId,
    String commandId,
  ) => _maintenance(
    deviceId,
    commandId,
    'forceCloseNonFiscal',
    'closeNonFiscalTest',
    (session) => closeFp21TestReceipt(session),
  );

  Future<HardwareResult> printQrTest(String deviceId, String commandId) =>
      _maintenance(deviceId, commandId, 'qrTest', 'qrTest', printFp21QrTest,
          payload: const {'url': fp21TestReceiptQrUrl, 'resolution': 4});

  Future<HardwareResult> cutPaper(String deviceId, String commandId) =>
      _maintenance(deviceId, commandId, 'cutPaper', 'cutPaper', cutFp21Paper);

  Future<HardwareResult> _maintenance(
    String deviceId,
    String commandId,
    String operation,
    String purpose,
    Future<HardwareResult> Function(ByteSession) perform, {
    Map<String, Object?> payload = const {},
  }) async {
    final log = await _commandJournal();
    return log.execute(
      id: commandId,
      deviceId: 'fp21-usb:$deviceId',
      operation: operation,
      payload: payload,
      dispatch: () => _onPort(deviceId, purpose, perform),
    );
  }

  Future<HardwareResult> _onPort(
    String deviceId,
    String purpose,
    Future<HardwareResult> Function(ByteSession) perform,
  ) async {
    late final _Fp21UsbSession session;
    try {
      session = await _open(deviceId, purpose: purpose);
    } catch (_) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Portul USB nu s-a deschis.',
      );
    }
    try {
      return await perform(session);
    } finally {
      // Detaching after the acknowledgement cannot undo the completed command.
      try {
        await session.close();
      } on PlatformException {
        /* handle detached */
      }
    }
  }

  Future<HardwareResult> finishInterruptedTest(
    String deviceId,
    String originalId,
  ) => _recoverTest(deviceId, originalId, closeOnly: false);

  Future<HardwareResult> closeInterruptedTest(
    String deviceId,
    String originalId,
  ) => _recoverTest(deviceId, originalId, closeOnly: true);

  Future<HardwareResult> _recoverTest(
    String deviceId,
    String originalId, {
    required bool closeOnly,
  }) async {
    final log = await _commandJournal();
    final journalDevice = 'fp21-usb:$deviceId';
    final operation = closeOnly ? 'closeNonFiscalTest' : 'finishNonFiscalTest';
    final history = closeOnly
        ? await log.latestDeviceCommands(journalDevice)
        : <Map<String, dynamic>>[];
    final retryId = 'fp21-close-after-display-$originalId';
    final replayRetry = history.firstOrNull?['id'] == retryId;
    final retryClose =
        closeOnly && _displayRefusedClose(journalDevice, history) == originalId;
    if (retryClose) {
      final status = await probe(deviceId);
      if (status.details['canCloseTestId'] != originalId) {
        return HardwareResult(
          CommandOutcome.rejected,
          message: status.description,
        );
      }
    }
    return log.execute(
      id: retryClose || replayRetry
          ? retryId
          : closeOnly
          ? 'fp21-close-$originalId'
          : 'fp21-finish-$originalId',
      deviceId: journalDevice,
      operation: operation,
      payload: {'originalCommandId': originalId},
      acceptsDeviceHistory: (history) => retryClose
          ? _displayRefusedClose(journalDevice, history) == originalId
          : closeOnly
          ? _closableTest(journalDevice, history) == originalId
          : history.firstOrNull?['id'] == originalId &&
                _matchesInterruptedSample(
                  journalDevice,
                  history.firstOrNull,
                  legacyOnly: true,
                ),
      dispatch: () => _onPort(
        deviceId,
        operation,
        (session) => closeOnly
            ? closeFp21TestReceipt(session, requireDisplay: retryClose)
            : finishFp21TestReceipt(session),
      ),
    );
  }
}

class _Fp21UsbSession implements ByteSession {
  _Fp21UsbSession(this.handle);
  final int handle;

  @override
  Future<List<int>> exchange(
    List<int> request,
    int? Function(List<int>) frameLength,
  ) async {
    try {
      await Fp21Usb.channel.invokeMethod<void>('write', {
        'session': handle,
        'bytes': Uint8List.fromList(request),
      });
      final bytes = <int>[];
      final elapsed = Stopwatch()..start();
      // Android allows an 8-second QR reply; its ACK can arrive fragmented.
      final qr = request.length >= 5 && request[3] == 0x51 && request[4] == 0x43;
      final deadline = Duration(seconds: qr ? 12 : 5);
      while (elapsed.elapsed < deadline) {
        final packet = await Fp21Usb.channel.invokeMethod<Uint8List>('read', {
          'session': handle,
        });
        if (packet == null || packet.isEmpty) {
          throw const FormatException('Răspuns USB incomplet.');
        }
        bytes.addAll(packet);
        final expected = frameLength(bytes);
        if (bytes.length > 259 || (expected != null && bytes.length > expected)) {
          throw const FormatException('Răspuns USB neașteptat.');
        }
        if (expected == bytes.length) return bytes;
      }
      throw TimeoutException('Imprimanta nu a răspuns la timp.');
    } on PlatformException catch (e) {
      throw Fp21UsbTransferFailure(e.code, e.message);
    }
  }

  @override
  Future<void> close() =>
      Fp21Usb.channel.invokeMethod<void>('close', {'session': handle});
}
