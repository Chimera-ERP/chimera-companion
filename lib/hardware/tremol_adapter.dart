import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'connection.dart';
import 'contracts.dart';
import 'money.dart';
import 'tcp_transport.dart';
import 'fiscal_byte_session.dart';
import 'fp21_test_receipt.dart';
import 'text_encoding.dart';
import 'tremol_protocol.dart';
import 'command_journal.dart';
import 'operator_change.dart';
import 'package:crypto/crypto.dart';

class TremolLanPasswordRequired implements Exception {
  const TremolLanPasswordRequired({this.rejected = false});
  final bool rejected;
  @override
  String toString() => rejected
      ? 'Casa a respins parola LAN. Verifică parola conexiunii Ethernet / Wi-Fi.'
      : 'Casa solicită parola conexiunii LAN. Nu este parola operatorului fiscal.';
}

class TremolPaperRequired implements Exception {
  const TremolPaperRequired();
  @override
  String toString() => 'Lipsă hârtie ECR. Înlocuiește rola și confirmă pe casa de marcat dacă solicită o tastă.';
}

class Fp21UsbTransferFailure implements Exception {
  const Fp21UsbTransferFailure(this.code, this.message);
  final String code;
  final String? message;
}

class _TremolCommandRefused extends StateError {
  _TremolCommandRefused(this.code, this.deviceFault, this.commandFault)
    : super('Tremol rejected command: $code');
  final int deviceFault;
  final int commandFault;
  String get hexadecimalCode => '${deviceFault.toRadixString(16)}${commandFault.toRadixString(16)}'.toUpperCase();
  final String code;
}

// The ZFPLab wire serializer fills its 200-byte QR data field with spaces.
final _fp21QrPayload = 'C;4;${fp21TestReceiptQrUrl.padRight(200)}';

class _TremolWire {
  _TremolWire(this.model, this.tcpPassword, [this.serialKey]);
  final String? serialKey;
  final FiscalModel model;
  final String tcpPassword;

  int _sequence = 0x20;
  int _nextSequence() {
    if (serialKey != null) return TremolProtocol.nextSerialSequence(serialKey!);
    final value = _sequence;
    _sequence = _sequence == 0x9f ? 0x20 : _sequence + 1;
    return value;
  }
  int? _singleByte(List<int> bytes) => bytes.isEmpty ? null : 1;

  Future<void> _waitReady(ByteSession session) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var authenticated = false;
    while (true) {
      var status = (await session.exchange([9], _singleByte)).single;
      if ((status & 2) != 0 && [0x40, 0x50].contains(status & 0xf0)) {
        throw const TremolPaperRequired();
      }
      if (status == 0x50 && tcpPassword.isEmpty) {
        throw const TremolLanPasswordRequired();
      }
      if (status == 0x50 &&
          !authenticated &&
          tcpPassword.isNotEmpty) {
        authenticated = true;
        status = (await session.exchange([
          ...ascii.encode(tcpPassword),
          10,
          9,
        ], _singleByte)).single;
      }
      if ((status & 2) != 0 && [0x40, 0x50].contains(status & 0xf0)) {
        throw const TremolPaperRequired();
      }
      if (status == 0x50) {
        throw const TremolLanPasswordRequired(rejected: true);
      }
      if ((status & 0xf0) != 0x40 ||
          (status & 6) != 0 ||
          (model != FiscalModel.tremolM20 && (status & 8) != 0)) {
        throw StateError(
          'Tremol connection/printer status: ${status.toRadixString(16)}',
        );
      }
      if ((status & 1) == 0) return;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Tremol remains busy');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<TremolFrame> _command(
    ByteSession session,
    int command,
    List<int> data, {
    bool ack = false,
    void Function()? beforeWrite,
  }) async {
    await _waitReady(session);
    final sequence = _nextSequence();
    beforeWrite?.call();
    final bytes = await session.exchange(
      TremolProtocol.encode(sequence, command, data),
      TremolProtocol.frameLength,
    );
    final frame = TremolProtocol.decode(
      bytes,
      sequence: sequence,
      command: command,
    );
    if (frame.error != null) {
      throw _TremolCommandRefused(frame.error!, bytes[2] - 0x30, bytes[3] - 0x30);
    }
    if (frame.isAck != ack) {
      throw const FormatException('Unexpected Tremol response type');
    }
    return frame;
  }

  Future<DeviceStatus> _status(
    ByteSession session, {
    bool localNonFiscal = false,
  }) async {
    final frame = await _command(session, 0x20, []);
    if (frame.data.length != 7) {
      throw const FormatException('Expected seven Tremol status bytes');
    }
    final b = frame.data;
    // RO 2601151250, ReadStatus: ST2.0 = non-fiscal open, ST2.1 = fiscal open.
    final openDocument = b[2] & 0x03;
    final statusBytes = b
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    // ST0.1 records a power interruption. A ready 09h reply and clear ST2
    // document bits allow a fresh local non-fiscal test after the old slip closes.
    final powerInterrupted = (b[0] & 0x02) != 0;
    final mechanicallyReady =
        (b[0] & 0x7d) == 0 &&
        (b[1] & 0x07) == 0 &&
        (b[2] & 0x40) == 0 &&
        (b[3] & 0x07) == 0 &&
        // For a USB non-fiscal sample, 09h must still report runtime readiness.
        // ST4.3 records a missing external customer display, not an open sale.
        ((localNonFiscal && (b[4] & 0x02) == 0) ||
            model == FiscalModel.tremolM20 ||
            (b[4] & 0x08) == 0) &&
        (b[5] & 0x33) == 0;
    final operable = mechanicallyReady && !powerInterrupted;
    final ready =
        mechanicallyReady && openDocument == 0 && (!powerInterrupted || localNonFiscal);
    return DeviceStatus(
      ready: ready,
      details: {
        'externalDisplayMissing': (b[4] & 8) != 0,
        'nonFiscalOpen': (openDocument & 1) != 0,
        'fiscalOpen': (openDocument & 2) != 0,
        'canCloseNonFiscal': mechanicallyReady && openDocument == 1,
        'canCutPaper': mechanicallyReady && openDocument < 2,
        'canFinishNonFiscal': operable && openDocument == 1,
        'paperOut': (b[1] & 1) != 0,
        'dailyReportNonZero': (b[1] & 8) != 0,
        'articleReportNonZero': (b[1] & 16) != 0,
        'operatorReportNonZero': (b[1] & 32) != 0,
        'statusBytes': statusBytes,
      },
      description: (b[1] & 1) != 0
          ? const TremolPaperRequired().toString()
          : ready && powerInterrupted
          ? 'Pregătit pentru testul nefiscal. Niciun bon deschis. '
                'FP21 semnalează o întrerupere anterioară de alimentare.'
          : ready
          ? 'Tremol pregătit'
          : mechanicallyReady && openDocument == 1 && powerInterrupted
          ? 'Document nefiscal deschis după o întrerupere de alimentare.'
          : operable && openDocument == 1
          ? 'Document nefiscal deschis.'
          : 'Tremol blocat sau cu document deschis. Stare ECR: $statusBytes',
    );
  }

  Future<HardwareResult> _nonFiscalDocument(
    ByteSession session, {
    required String openParameters,
    required List<String> lines,
    bool fp21Sample = false,
  }) async {
    var dispatched = false;
    var opened = false;
    try {
      final status = await _status(session, localNonFiscal: fp21Sample);
      if (!status.ready) {
        return HardwareResult(
          CommandOutcome.rejected,
          message: status.description,
        );
      }
      await _command(
        session,
        0x2e,
        ascii.encode(openParameters),
        ack: true,
        beforeWrite: () => dispatched = true,
      );
      opened = true;
      for (final line in lines) {
        await _command(session, 0x37, ascii.encode(line), ack: true);
      }
      if (fp21Sample) return await _finishTest(session);
      await _command(session, 0x2f, [], ack: true);
      return const HardwareResult(
        CommandOutcome.succeeded,
        message: 'Document nefiscal confirmat de Tremol',
      );
    } on _TremolCommandRefused catch (error) {
      if (!opened) {
        return HardwareResult(
          CommandOutcome.rejected,
          message:
              'Imprimanta a refuzat comanda (cod ${error.code}). Verifică starea și operatorul.',
        );
      }
      return HardwareResult(
        CommandOutcome.unknown,
        message:
            'Tipărire întreruptă (cod ${error.code}). Verifică hârtia și documentul pe imprimantă.',
      );
    } catch (_) {
      return HardwareResult(
        dispatched ? CommandOutcome.unknown : CommandOutcome.rejected,
        message: 'Tipărire neconfirmată. Verifică documentul pe imprimantă.',
      );
    }
  }

  Future<HardwareResult> _finishTest(ByteSession session) async {
    final refused = <String>[];
    final confirmed = <String>[];
    var phase = 'EAN-13';
    var qrDispatchStarted = false;
    try {
      // The printer calculates the EAN-13 check digit from its 12 data digits.
      final digits = fp21TestReceiptBarcode.substring(0, 12);
      final symbols = [
        ('EAN-13', 'P;2;12;${digits.padRight(100)}'),
        ('QR', _fp21QrPayload),
      ];
      for (final (name, payload) in symbols) {
        phase = name;
        try {
          await _command(
            session,
            0x51,
            ascii.encode(payload),
            ack: true,
            beforeWrite: () => qrDispatchStarted = name == 'QR',
          );
          confirmed.add(name);
        } on TremolCommandNotExecuted catch (e) {
          refused.add('$name (${e.toString()})');
        } on _TremolCommandRefused catch (e) {
          // An explicit syntax/unsupported-command reply is conclusive for
          // this symbol. A lost ACK must never trigger a second print.
          if (!{0, 6, 10}.contains(e.deviceFault) ||
              !{1, 2, 4}.contains(e.commandFault)) {
            rethrow;
          }
          refused.add('$name (cod ${e.hexadecimalCode})');
        }
      }
      phase = 'finalul bonului';
      for (final line in fp21TestReceiptFooter) {
        await _command(session, 0x37, ascii.encode(line), ack: true);
      }
      phase = 'închiderea bonului';
      await _command(session, 0x2f, [], ack: true);
    } catch (e) {
      final reason = switch (e) {
        _TremolCommandRefused() => 'cod ${e.hexadecimalCode}',
        Fp21UsbTransferFailure() => e.code,
        FormatException() => 'răspuns Tremol invalid',
        TimeoutException() => 'timp de răspuns depășit',
        TremolPaperRequired() => 'lipsă hârtie',
        _ => 'răspuns indisponibil',
      };
      String? closeMessage;
      if (phase == 'QR' && qrDispatchStarted &&
          e is Fp21UsbTransferFailure && e.code == 'USB_READ') {
        // The USB adapter retains this same attachment for status and one
        // verified non-fiscal close. An uncertain symbol is never replayed.
        try {
          final close = await closeFp21TestReceipt(session);
          closeMessage = close.message;
        } catch (_) {
          closeMessage = 'Închiderea bonului nu a fost confirmată.';
        }
      }
      final previous = [
        if (confirmed.isNotEmpty) 'Acceptat: ${confirmed.join(', ')}.',
        if (refused.isNotEmpty) 'Refuzat: ${refused.join(', ')}.',
      ].join(' ');
      return HardwareResult(
        CommandOutcome.unknown,
        message: [
          if (previous.isNotEmpty) previous,
          'Tipărire neconfirmată la $phase ($reason).',
          ?closeMessage,
        ].join(' '),
      );
    }
    if (refused.isEmpty) {
      return const HardwareResult(
        CommandOutcome.succeeded,
        message: 'Bon închis. FP21 a acceptat EAN-13 și QR. Verifică ambele coduri prin scanare.',
      );
    }
    final accepted = confirmed.isEmpty ? '' : ' A acceptat ${confirmed.join(', ')}.';
    return HardwareResult(
      CommandOutcome.rejected,
      message: 'Bon închis. FP21 a refuzat ${refused.join(' și ')}.$accepted',
    );
  }
}

// A new transport handle should not restart the protocol sequence on each tap.
final _fp21UsbWire = _TremolWire(FiscalModel.tremolFp21, '');

Future<DeviceStatus> readFp21Status(
  ByteSession session, {
  bool includeFirmware = false,
}) async {
  final status = await _fp21UsbWire._status(session, localNonFiscal: true);
  if (!includeFirmware || !status.ready) return status;
  try {
    // RO §2.2.2 ReadVersion: up to 100 model/firmware bytes, no input.
    final frame = await _fp21UsbWire._command(session, 0x21, []);
    if (frame.data.length > 100) return status;
    final firmware = String.fromCharCodes(frame.data)
        .replaceAll(RegExp(r'[^ -~]+'), ' ')
        .replaceAll(RegExp(r' +'), ' ')
        .trim();
    if (firmware.isEmpty) return status;
    return DeviceStatus(
      ready: status.ready,
      description: '${status.description} Model / firmware: $firmware',
      details: {...status.details, 'firmware': firmware},
    );
  } on Exception {
    return status;
  } on StateError {
    // A refused version read does not invalidate the confirmed 20h reply.
    return status;
  }
}

Future<HardwareResult> finishFp21TestReceipt(ByteSession session) async {
  final status = await readFp21Status(session);
  if (status.details['canFinishNonFiscal'] != true) {
    return HardwareResult(CommandOutcome.rejected, message: status.description);
  }
  return _fp21UsbWire._finishTest(session);
}

Future<HardwareResult> closeFp21TestReceipt(
  ByteSession session, {
  bool requireDisplay = false,
}) async {
  final before = await readFp21Status(session);
  if (requireDisplay && before.details['externalDisplayMissing'] != false) {
    return const HardwareResult(
      CommandOutcome.rejected,
      message: 'FP21 semnalează în continuare lipsa afișajului client.',
    );
  }
  if (before.details['canCloseNonFiscal'] != true) {
    return HardwareResult(CommandOutcome.rejected, message: before.ready
        ? 'Imprimanta nu are niciun bon nefiscal deschis.'
        : before.description);
  }
  String? refusal;
  try {
    // No text, barcode, payment, cancel, or receipt opening on this path.
    await _fp21UsbWire._command(session, 0x2f, [], ack: true);
  } on _TremolCommandRefused catch (error) {
    refusal = error.hexadecimalCode;
  } catch (_) {
    // A lost response is reconciled only by reading the printer state.
  }
  try {
    final after = await readFp21Status(session);
    if (after.details['nonFiscalOpen'] == false &&
        after.details['fiscalOpen'] == false) {
      return const HardwareResult(
        CommandOutcome.succeeded,
        message:
            'Bon nefiscal închis. FP21 confirmă că nu mai are niciun document deschis.',
      );
    }
  } catch (_) {
    // The same command must not be resent on an uncertain result.
  }
  return HardwareResult(
    CommandOutcome.unknown,
    message: refusal == null
        ? 'Închiderea bonului nu a fost confirmată. Citește din nou starea imprimantei.'
        : 'Închidere neconfirmată de FP21 (cod $refusal). Verifică starea imprimantei.',
  );
}

Future<HardwareResult> printFp21QrTest(ByteSession session) async {
  var dispatchStarted = false;
  try {
    final status = await readFp21Status(session);
    if (!status.ready) {
      return HardwareResult(CommandOutcome.rejected, message: status.description);
    }
    await _fp21UsbWire._command(
      session,
      0x51,
      ascii.encode(_fp21QrPayload),
      ack: true,
      beforeWrite: () => dispatchStarted = true,
    );
    return const HardwareResult(
      CommandOutcome.succeeded,
      message: 'FP21 a acceptat comanda QR. Verifică pe hârtie dacă se scanează https://chimeraerp.ro.',
    );
  } on _TremolCommandRefused catch (e) {
    return HardwareResult(
      CommandOutcome.rejected,
      message: dispatchStarted
          ? 'FP21 a refuzat comanda QR (cod ${e.hexadecimalCode}).'
          : 'FP21 a refuzat citirea stării (cod ${e.hexadecimalCode}).',
    );
  } on TremolCommandNotExecuted catch (e) {
    return HardwareResult(
      CommandOutcome.rejected,
      message: 'FP21 a refuzat ${dispatchStarted ? 'comanda QR' : 'citirea stării'} ($e).',
    );
  } catch (e) {
    final reason = switch (e) {
      Fp21UsbTransferFailure() => e.code,
      FormatException() => 'răspuns Tremol invalid',
      TimeoutException() => 'timp de răspuns depășit',
      _ => 'imprimantă indisponibilă',
    };
    return HardwareResult(
      dispatchStarted ? CommandOutcome.unknown : CommandOutcome.rejected,
      message: dispatchStarted
          ? 'Comanda QR nu a fost confirmată ($reason).'
          : 'Proba QR s-a oprit înainte de trimitere ($reason).',
    );
  }
}

Future<HardwareResult> cutFp21Paper(ByteSession session) async {
  final before = await readFp21Status(session);
  if (before.details['canCutPaper'] != true) {
    return HardwareResult(CommandOutcome.rejected, message: before.description);
  }
  try {
    await _fp21UsbWire._command(session, 0x29, [], ack: true);
    return const HardwareResult(CommandOutcome.succeeded, message: 'FP21 a confirmat comanda de tăiere a hârtiei.');
  } on _TremolCommandRefused catch (error) {
    return HardwareResult(CommandOutcome.rejected, message: 'FP21 a refuzat tăierea hârtiei (cod ${error.hexadecimalCode}).');
  } catch (_) {
    return const HardwareResult(CommandOutcome.unknown, message: 'Tăiere neconfirmată. Verifică hârtia.');
  }
}

Future<HardwareResult> printFp21TestReceipt(
  ByteSession session, {
  required int operatorNumber,
  required String operatorPassword,
}) {
  if (operatorNumber < 1 ||
      operatorNumber > 20 ||
      operatorPassword.length != 4 ||
      operatorPassword.codeUnits.any((c) => c < 32 || c > 126 || c == 59)) {
    throw ArgumentError('Date operator FP21 invalide.');
  }
  return _fp21UsbWire._nonFiscalDocument(
    session,
    openParameters: '$operatorNumber;$operatorPassword;0;0',
    lines: fp21TestReceiptLines,
    fp21Sample: true,
  );
}

enum Fp21BluetoothState {
  unsupportedFirmware,
  moduleAbsent,
  disabled,
  enabled,
  unconfirmed,
}

/// Local USB setup for one selected register. The factory serial is checked by
/// FiscalByteSession on this handle before any module command is sent.
class Fp21Bluetooth extends _TremolWire {
  Fp21Bluetooth(this.endpoint)
    : super(FiscalModel.tremolFp21, '', endpoint.key) {
    if (endpoint.model != FiscalModel.tremolFp21 ||
        endpoint.transport != 'usb') {
      throw ArgumentError('Selectează casa Activa FP21 conectată prin USB.');
    }
  }

  final FiscalSerialEndpoint endpoint;

  Future<Fp21BluetoothState> readState() => _inspect(enable: false);

  Future<Fp21BluetoothState> enable() => _inspect(enable: true);

  Future<List<String>> _read(ByteSession session, String key) async {
    final frame = await _command(session, 0x4e, ascii.encode(key));
    final fields = ascii.decode(frame.data).split(';');
    if (fields.last.isEmpty) fields.removeLast();
    return fields;
  }

  /// All four flags must have the vendor's documented shape. The attached RO
  /// 2.00TRP21_AC also echoes R;D;S for R;D;D. A positive report still
  /// requires a separate valid R;B;S response before enabling anything.
  Future<bool> _moduleSupport(
    ByteSession session, {
    required bool firmware,
  }) async {
    final key = firmware ? 'S' : 'D';
    final fields = await _read(session, 'R;D;$key');
    if (fields.length != 7 ||
        fields[0] != 'R' ||
        fields[1] != 'D' ||
        !(fields[2] == key || (!firmware && fields[2] == 'S')) ||
        fields.skip(3).any((bit) => bit != '0' && bit != '1')) {
      throw const FormatException(
        'Răspuns nevalid la verificarea modulului Bluetooth.',
      );
    }
    if (!firmware && fields[2] == 'S' && fields.last == '0') {
      throw const FormatException(
        'Prezența modulului Bluetooth nu a fost confirmată.',
      );
    }
    return fields.last == '1';
  }

  Future<Fp21BluetoothState> _radio(ByteSession session) async {
    final fields = await _read(session, 'R;B;S');
    if (fields.length != 4 ||
        fields[0] != 'R' ||
        fields[1] != 'B' ||
        fields[2] != 'S') {
      throw const FormatException(
        'Răspuns nevalid la citirea stării Bluetooth.',
      );
    }
    return switch (fields.last) {
      '0' => Fp21BluetoothState.disabled,
      '1' => Fp21BluetoothState.enabled,
      _ => throw const FormatException('Stare Bluetooth necunoscută.'),
    };
  }

  Future<Fp21BluetoothState> _inspect({required bool enable}) async {
    final session = await FiscalByteSession.connect(endpoint);
    var writeStarted = false;
    try {
      if (!await _moduleSupport(session, firmware: true)) {
        return Fp21BluetoothState.unsupportedFirmware;
      }
      if (!await _moduleSupport(session, firmware: false)) {
        return Fp21BluetoothState.moduleAbsent;
      }
      final current = await _radio(session);
      if (!enable || current == Fp21BluetoothState.enabled) return current;

      final status = await _status(session, localNonFiscal: true);
      if (status.details['fiscalOpen'] == true ||
          status.details['nonFiscalOpen'] == true) {
        throw StateError(
          'Închide documentul deschis înainte de a activa Bluetooth.',
        );
      }
      await _command(
        session,
        0x4e,
        ascii.encode('P;B;S;1'),
        ack: true,
        beforeWrite: () => writeStarted = true,
      );
      return await _radio(session);
    } catch (_) {
      if (!writeStarted) rethrow;
      // Only a fresh radio status can establish the result after a lost reply.
      return Fp21BluetoothState.unconfirmed;
    } finally {
      await session.close();
    }
  }
}

class TremolAdapter extends _TremolWire implements FiscalDeviceAdapter {
  TremolAdapter(this.connection, {SessionFactory? sessions, this.checkpoint})
    : _sessions = sessions ?? FiscalByteSession.connect,
      super(connection.model, connection.target is LanEndpoint ? connection.tcpPassword : '',
          connection.target is FiscalSerialEndpoint ? connection.target.key : null) {
    if (connection.model == FiscalModel.datecsDp25) {
      throw ArgumentError('Not a Tremol model');
    }
  }
  final FiscalConnection connection;
  final Future<void> Function(Map<String,dynamic>)? checkpoint;
  static List<String> receiptMarkers(String id) {
    final hash=sha256.convert(utf8.encode(id)).toString();
    return ['CHM1:${hash.substring(0,24)}','CHM2:${hash.substring(24,48)}','CHM3:${hash.substring(48)}'];
  }

  Future<Map<String,dynamic>> _receiptIdentity(ByteSession session) async {
    final serial = TremolProtocol.manufacturingNumber(model, (await _command(session, 0x60, [])).data);
    final fields=ascii.decode((await _command(session,0x71,[])).data).split(';');
    if(fields.length!=2||!RegExp(r'^\d{4}$').hasMatch(fields[0])||!RegExp(r'^\d{7}$').hasMatch(fields[1]))throw const FormatException('Invalid fiscal identity');
    return {'serial':serial,'z':fields[0],'number':int.parse(fields[1])};
  }

  /// Bounded ACK + framed EJ stream; '@' terminates only at a frame boundary.
  /// Reference: RO2601151250 7Ch and vendor JS demo fpEJReport/RawRead.
  Future<String> _readReceipt(ByteSession session,int number) async {
    if(number<1||number>999999)throw ArgumentError('EJ receipt range');
    await _waitReady(session);
    final sequence = _nextSequence();
    int? length(List<int> bytes){
      if(bytes.length>65536)throw const FormatException('EJ response too large');
      var offset=0;
      while(offset<bytes.length){
        if(offset>0&&bytes[offset]==0x40)return offset+1;
        final size=TremolProtocol.frameLength(bytes.sublist(offset));
        if(size==null||bytes.length-offset<size)return null;
        offset+=size;
      }
      return null;
    }
    final n=number.toString().padLeft(6,'0');
    final bytes=await session.exchange(TremolProtocol.encode(sequence,0x7c,ascii.encode('J0;N;$n;$n')),length);
    var offset=0;final lines=<String>[];
    while(offset<bytes.length-1){
      final size=TremolProtocol.frameLength(bytes.sublist(offset))!;
      final chunk=bytes.sublist(offset,offset+size);
      final frame=TremolProtocol.decode(chunk,sequence:offset==0?sequence:chunk[2],command:0x7c);
      if(frame.error!=null||offset==0&&!frame.isAck||offset>0&&frame.isAck)throw const FormatException('Invalid EJ stream');
      if(!frame.isAck)lines.add(latin1.decode(frame.data).trim());
      offset+=size;
    }
    if(bytes.last!=0x40)throw const FormatException('Incomplete EJ');
    return lines.join('\n');
  }

  Future<HardwareResult> reconcileReceipt(String id,Map<String,dynamic>? evidence) async {
    const unknown=HardwareResult(CommandOutcome.unknown,message:'Bonul nu poate fi identificat sigur în casa de marcat. Necesită verificare; nu se reemite.');
    if(evidence?['closed']!=true||evidence?['commandId']!=id||evidence?['before'] is! Map)return unknown;
    if(_busy)return unknown;_busy=true;ByteSession? session;
    try {
      session=await _sessions(connection.target);
      final before=Map<String,dynamic>.from(evidence!['before']);
      final current=await _receiptIdentity(session);
      final number=(before['number'] as int)+1;
      if(current['serial']!=before['serial']||current['z']!=before['z']||current['number']!=number)return unknown;
      final text=await _readReceipt(session,number);
      if(!receiptMarkers(id).every((marker)=>text.split('\n').contains(marker)))return unknown;
      return HardwareResult(CommandOutcome.succeeded,reference:'${number.toString().padLeft(7,'0')}:${current['z']}',message:'Bon identificat în jurnalul electronic Tremol',
        fiscalIdentity:{'serialNumber':current['serial'] as String,'receiptNumber':number.toString().padLeft(7,'0'),'zNumber':current['z'] as String,'documentMode':'fiscal','fiscalEmittedAt':evidence['closedAt'] as String});
    }catch(_){return unknown;}finally{await session?.close();_busy=false;}
  }
  final SessionFactory _sessions;
  Future<Map<String, Object?>> setOperator({
    required String deviceId, required String commandId,
    required Map<String, dynamic> identity, required bool ending,
    required CommandJournal journal,
    required Future<Map<String, dynamic>?> Function(String) read,
    required Future<void> Function(String, Map<String, dynamic>) write,
  }) {
    final workflow = OperatorChange(journal: journal, read: read, write: write,
      state: operatorChangeState, rename: renameConfiguredOperator,
      reset: resetConfiguredOperatorReport);
    return ending ? workflow.logout(deviceId, commandId, identity)
        : workflow.runAutomatic(deviceId, commandId, identity);
  }
  bool _busy = false;

  @override
  String get vendor => 'tremol';

  @override
  Future<DeviceStatus> readStatus() async {
    if (_busy) {
      return const DeviceStatus(ready: false, description: 'Comandă în curs');
    }
    _busy = true;
    ByteSession? session;
    try {
      session = await _sessions(connection.target);
      return await _status(session);
    } on TremolPaperRequired {
      return DeviceStatus(ready: false,
        description: const TremolPaperRequired().toString(),
        details: const {'paperOut': true});
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  /// Read-only setup discovery. Never log or return the password over the LAN API.
  Future<Map<String, String>> readOperatorConfiguration() async {
    if (_busy) throw StateError('Dispozitiv ocupat');
    _busy = true;
    ByteSession? session;
    try {
      session = await _sessions(connection.target);
      final response = await _command(
        session,
        0x6a,
        ascii.encode('${connection.operatorNumber}'),
      );
      final parts = latin1.decode(response.data).split(';');
      if (parts.length == 4 && parts.last.isEmpty) parts.removeLast();
      if (parts.length != 3 ||
          int.tryParse(parts[0]) != connection.operatorNumber ||
          parts[2].length != 4) {
        throw FormatException(
          'Invalid operator configuration: ${parts.map((part) => part.length).join(',')}',
        );
      }
      return {'name': parts[1].trim(), 'password': parts[2]};
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  Future<Map<String, double>> readVatRates() async {
    if (_busy) throw StateError('Dispozitiv ocupat');
    _busy = true;
    ByteSession? session;
    try {
      session = await _sessions(connection.target);
      final frame = await _command(session, 0x62, []);
      final parts = ascii.decode(frame.data).split(';');
      if (parts.length < 5) throw const FormatException('Invalid VAT rates');
      return {
        for (var i = 0; i < 5; i++)
          String.fromCharCode(65 + i): double.parse(
            parts[i].replaceAll('%', '').trim(),
          ),
      };
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  Future<HardwareResult> renameConfiguredOperator(String name) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty || cleaned.contains(';')) {
      throw ArgumentError('Invalid operator name');
    }
    final nameBytes = encodeFiscalText(cleaned, maxBytes: 20);
    if (_busy) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'ECR ocupat',
      );
    }
    _busy = true;
    ByteSession? session;
    var dispatched = false;
    var phase = 'citire stare (20h)';
    try {
      session = await _sessions(connection.target);
      if (!(await _status(session)).ready) {
        return const HardwareResult(
          CommandOutcome.rejected,
          message:
              'ECR nu permite schimbarea operatorului în starea curentă. Nu s-a emis Z.',
        );
      }
      phase = 'citire operator (6Ah)';
      final before = latin1
          .decode(
            (await _command(
              session,
              0x6a,
              ascii.encode('${connection.operatorNumber}'),
            )).data,
          )
          .split(';');
      if (before.length < 3 || before[2].length != 4) {
        throw const FormatException('Invalid operator response');
      }
      if (before[1].trim() == cleaned) {
        return HardwareResult(
          CommandOutcome.succeeded,
          message: 'Operator ECR: $cleaned',
        );
      }
      dispatched = true;
      phase = 'programare nume/parolă operator (4Ah)';
      await _command(session, 0x4a, [
        ...ascii.encode('${connection.operatorNumber};'),
        ...nameBytes,
        ...List.filled(20 - nameBytes.length, 32),
        ...ascii.encode(';${before[2]}'),
      ], ack: true);
      phase = 'verificare operator (6Ah)';
      final after = latin1
          .decode(
            (await _command(
              session,
              0x6a,
              ascii.encode('${connection.operatorNumber}'),
            )).data,
          )
          .split(';');
      if (after.length < 3 ||
          after[1].trim() != cleaned ||
          after[2] != before[2]) {
        throw const FormatException('Operator readback mismatch');
      }
      return HardwareResult(
        CommandOutcome.succeeded,
        message: 'Operator ECR: $cleaned',
      );
    } catch (error) {
      if (error is StateError &&
          error.message.toString().startsWith('Tremol rejected command:')) {
        return HardwareResult(
          CommandOutcome.rejected,
          reference: error.message.toString() == 'Tremol rejected command: 03'
              ? 'daily_report_not_zero'
              : null,
          message:
              error.message.toString() == 'Tremol rejected command: 03'
                ? 'ECR refuză $phase: cod 03 (registrul zilnic nu este zero, conform protocolului). Verifică starea fiscală din diagnostic; nu repeta automat rapoartele.'
                : 'ECR refuză $phase: ${error.message}.',
        );
      }
      return HardwareResult(
        dispatched ? CommandOutcome.unknown : CommandOutcome.rejected,
        message: dispatched
            ? 'Schimbarea operatorului nu este confirmată; verifică ECR.'
            : error is SocketException || error is TimeoutException
            ? 'Casa de marcat nu răspunde: poate fi oprită sau inaccesibilă în rețea. Verifică alimentarea și conexiunea LAN, apoi reverifică.'
            : error is TremolLanPasswordRequired
            ? error.toString()
            : 'Casa a răspuns, dar operatorul nu a putut fi verificat. Verifică configurarea ECR în Companion.',
      );
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  Future<Map<String, String>> operatorChangeState() async {
    if (_busy) throw StateError('ECR ocupat');
    _busy = true;
    ByteSession? session;
    try {
      session = await _sessions(connection.target);
      if (!(await _status(session)).ready) {
        throw StateError('ECR nu este pregătit');
      }
      final op = latin1
          .decode(
            (await _command(
              session,
              0x6a,
              ascii.encode('${connection.operatorNumber}'),
            )).data,
          )
          .split(';');
      if (op.length < 3) throw const FormatException('Invalid operator');
      final counters = ascii.decode(
        (await _command(
          session,
          0x6f,
          ascii.encode('1;${connection.operatorNumber}'),
        )).data,
      );
      return {'name': op[1].trim(), 'counters': counters};
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  Future<HardwareResult> resetConfiguredOperatorReport() async {
    if (_busy) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'ECR ocupat',
      );
    }
    _busy = true;
    ByteSession? session;
    var sent = false;
    try {
      session = await _sessions(connection.target);
      if (!(await _status(session)).ready) {
        return const HardwareResult(
          CommandOutcome.rejected,
          message: 'ECR nu este pregătit',
        );
      }
      sent = true;
      // 0x7d is the operator report, not fiscal-day closure (0x7c).
      // RO protocol requires Number=0 (all operators) for a Z operator report.
      await _command(
        session,
        0x7d,
        ascii.encode('Z;0'),
        ack: true,
      );
      return const HardwareResult(
        CommandOutcome.succeeded,
        message:
            'Raportul tuturor operatorilor a fost tipărit cu golire. Ziua fiscală nu a fost închisă.',
      );
    } catch (error) {
      final rejected =
          error is StateError &&
          error.message.toString().startsWith('Tremol rejected command:');
      return HardwareResult(
        rejected || !sent ? CommandOutcome.rejected : CommandOutcome.unknown,
        message:
            'Raportul operatorului nu este confirmat. Verifică ECR; nu repeta golirea.',
      );
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  /// Service console: framing/authentication only, never resend a command.
  Future<HardwareResult> rawCommand(int command, List<int> data) async {
    TremolProtocol.encode(0x20, command, data); // validate before connecting
    if (_busy) return const HardwareResult(CommandOutcome.rejected, message: 'ECR ocupat');
    _busy = true;
    ByteSession? session;
    var sent = false;
    try {
      session = await _sessions(connection.target);
      await _waitReady(session);
      sent = true;
      final sequence = _nextSequence();
      final response = await session.exchange(
        TremolProtocol.encode(sequence, command, data), TremolProtocol.frameLength);
      final frame = TremolProtocol.decode(response, sequence: sequence, command: command);
      return HardwareResult(frame.error == null ? CommandOutcome.succeeded : CommandOutcome.rejected,
        message: 'RX ${response.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}${frame.error == null ? '' : ' · ECR ${frame.error}'}');
    } catch (_) {
      return HardwareResult(sent ? CommandOutcome.unknown : CommandOutcome.rejected,
        message: sent ? 'Răspuns neconfirmat. Nu repeta automat comanda.' : 'Conexiune ECR indisponibilă.');
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  /// Daily totals without zeroing. Deliberately no caller-supplied report type:
  /// a diagnostic X report must never turn into a fiscal-day closure (Z).
  Future<HardwareResult> printXReport() => printReport(closeDay: false);

  Future<HardwareResult> printReport({required bool closeDay}) async {
    if (_busy) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Dispozitiv ocupat',
      );
    }
    _busy = true;
    ByteSession? session;
    var dispatched = false;
    try {
      session = await _sessions(connection.target);
      if (!(await _status(session)).ready) {
        return const HardwareResult(
          CommandOutcome.rejected,
          message: 'ECR nu este pregătit',
        );
      }
      dispatched = true;
      await _command(
        session,
        0x7c,
        ascii.encode(closeDay ? 'Z' : 'X'),
        ack: true,
      );
      if (!closeDay) await _waitReady(session);
      return HardwareResult(
        CommandOutcome.succeeded,
        message: closeDay
            ? 'Raport Z confirmat · ziua fiscală închisă'
            : 'Raport X tipărit, fără închiderea zilei',
      );
    } catch (_) {
      return HardwareResult(
        dispatched ? CommandOutcome.unknown : CommandOutcome.rejected,
        message: 'Raport ${closeDay ? 'Z' : 'X'} neconfirmat; verifică ECR-ul',
      );
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  Future<HardwareResult> printNonFiscal(List<String> lines) async {
    if (lines.isEmpty ||
        lines.length > 100 ||
        lines.any(
          (line) =>
              line.length > 40 || line.codeUnits.any((b) => b < 32 || b > 126),
        )) {
      throw ArgumentError('Invalid non-fiscal lines');
    }
    if (_busy) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Dispozitiv ocupat',
      );
    }
    _busy = true;
    ByteSession? session;
    try {
      session = await _sessions(connection.target);
      return await _nonFiscalDocument(
        session,
        openParameters:
            '${connection.operatorNumber};${connection.operatorPassword}',
        lines: lines,
      );
    } catch (_) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Conexiunea la imprimantă a eșuat.',
      );
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  /// Pure preparation, before opening a fiscal document. No command injection,
  /// implicit VAT mapping, price conversion or unsupported discount semantics.
  List<List<int>> prepareLines(FiscalReceiptDraft receipt) => receipt.lines.map((
    line,
  ) {
    if (!RegExp(r'^[A-E]$').hasMatch(line.vatGroup) ||
        line.name.contains(';') ||
        line.name.contains('`') ||
        minorToDecimal(line.unitPriceMinor).length > 10 ||
        line.quantityDecimal.length > 10) {
      throw ArgumentError('Unsupported Tremol fiscal line');
    }
    final name = encodeFiscalText(line.name, maxBytes: 30);
    return [
      ...name,
      ...List.filled(36 - name.length, 0x20),
      ...ascii.encode(
        ';${line.vatGroup};${minorToDecimal(line.unitPriceMinor)}*${line.quantityDecimal}',
      ),
    ];
  }).toList();

  List<String> prepareTenders(FiscalReceiptDraft receipt) => [
    for (final payment in receipt.payments)
      '${connection.paymentCode(payment.method)};0;${minorToDecimal(payment.amountMinor)};1',
  ];

  @override
  Future<HardwareResult> printReceipt(FiscalReceipt receipt) async {
    final lines = prepareLines(receipt);
    final tenders = prepareTenders(receipt);
    if (_busy) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Dispozitiv ocupat',
      );
    }
    _busy = true;
    ByteSession? session;
    bool dispatched = false;
    Map<String,dynamic>? evidence;
    try {
      session = await _sessions(connection.target);
      if (!(await _status(session)).ready) {
        return const HardwareResult(
          CommandOutcome.rejected,
          message: 'ECR nu este pregătit',
        );
      }
      if(checkpoint!=null){
        evidence={'commandId':receipt.commandId,'before':await _receiptIdentity(session),'closed':false};
        await checkpoint!(evidence);
      }
      dispatched = true;
      await _command(
        session,
        0x30,
        ascii.encode(
          receipt.cui == null
            ? '${connection.operatorNumber};${connection.operatorPassword};0;0;0'
            : '${connection.operatorNumber};${connection.operatorPassword};0;0;1;${receipt.cui!.padRight(15)};${' '.padRight(30)};${' '.padRight(20)};${' '.padRight(20)};${' '.padRight(20)};${' '.padRight(20)};${' '.padRight(30)}',
        ),
        ack: true,
      );
      for (final line in lines) {
        await _command(session, 0x31, line, ack: true);
      }
      final subtotal = await _command(session, 0x33, ascii.encode('0;0'));
      if (decimalToMinor(ascii.decode(subtotal.data)) != receipt.totalMinor) {
        throw StateError(
          'ECR subtotal differs; document left open for investigation',
        );
      }
      for (final tender in tenders) {
        await _command(session, 0x35, ascii.encode(tender), ack: true);
      }
      if(receipt.claimToken!=null){
        await _command(session,0x37,ascii.encode('Fidelity: ${receipt.claimToken}'),ack:true);
        await _command(session,0x51,ascii.encode('P;I;12;${receipt.claimToken}'),ack:true);
      }
      if(evidence!=null){
        for(final marker in receiptMarkers(receipt.commandId)){
          await _command(session,0x37,ascii.encode(marker),ack:true);
        }
      }
      await _command(session, 0x38, [], ack: true);
      if(evidence!=null){
        evidence={...evidence,'closed':true,'closedAt':DateTime.now().toUtc().toIso8601String()};
        await checkpoint!(evidence);
      }
      final counter = await _command(session, 0x71, []);
      final fields = ascii.decode(counter.data).split(';');
      if (fields.length != 2 ||
          !RegExp(r'^\d{4}$').hasMatch(fields[0]) ||
          !RegExp(r'^\d{7}$').hasMatch(fields[1])) {
        throw const FormatException('Missing fiscal receipt identity');
      }
      return HardwareResult(
        CommandOutcome.succeeded,
        reference: '${fields[1]}:${fields[0]}',
        fiscalIdentity: {'receiptNumber':fields[1],'zNumber':fields[0]},
        message: 'Bon confirmat de Tremol',
      );
    } catch (_) {
      return HardwareResult(
        dispatched ? CommandOutcome.unknown : CommandOutcome.rejected,
        message: dispatched
            ? 'Rezultat incert. Nu retrimite bonul; verifică ECR-ul.'
            : 'Conexiune sau stare ECR indisponibilă',
      );
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  /// Romania protocol 2601151250, section 2.6.20, 3Bh. A negative amount is
  /// paid out; an ACK confirms the operation, never an optimistic UI status.
  Future<HardwareResult> cashMovement(CashMovementRequest movement) async {
    final reason=encodeFiscalText(movement.reason,maxBytes:30);
    if(_busy)return const HardwareResult(CommandOutcome.rejected,message:'Dispozitiv ocupat');
    _busy=true;
    ByteSession? session;bool dispatched=false;
    try {
      session=await _sessions(connection.target);
      if(!(await _status(session)).ready)return const HardwareResult(CommandOutcome.rejected,message:'ECR nu este pregătit');
      dispatched=true;
      await _command(session,0x3b,[
        ...ascii.encode('${connection.operatorNumber};${connection.operatorPassword};0;${movement.withdrawal?'-':''}${minorToDecimal(movement.amountMinor)}@'),
        ...reason,
      ],ack:true);
      return HardwareResult(CommandOutcome.succeeded,reference:movement.commandId,message:'Mișcare numerar confirmată de ECR');
    } catch(_) {
      return HardwareResult(dispatched?CommandOutcome.unknown:CommandOutcome.rejected,message:dispatched?'Rezultat numerar incert. Nu repeta operația cu alt identificator.':'Casa este indisponibilă');
    } finally {await session?.close();_busy=false;}
  }
}
