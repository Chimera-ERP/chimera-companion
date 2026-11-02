import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'connection.dart';
import 'contracts.dart';
import 'money.dart';
import 'tcp_transport.dart';
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

class TremolAdapter implements FiscalDeviceAdapter {
  TremolAdapter(this.connection, {SessionFactory? sessions, this.checkpoint})
    : _sessions = sessions ?? TcpByteSession.connect {
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
    final serial=ascii.decode((await _command(session,0x60,[])).data).trim();
    final fields=ascii.decode((await _command(session,0x71,[])).data).split(';');
    if(serial.length!=11||fields.length!=2||!RegExp(r'^\d{4}$').hasMatch(fields[0])||!RegExp(r'^\d{7}$').hasMatch(fields[1]))throw const FormatException('Invalid fiscal identity');
    return {'serial':serial,'z':fields[0],'number':int.parse(fields[1])};
  }

  /// Bounded ACK + framed EJ stream; '@' terminates only at a frame boundary.
  /// Reference: RO2601151250 7Ch and vendor JS demo fpEJReport/RawRead.
  Future<String> _readReceipt(ByteSession session,int number) async {
    if(number<1||number>999999)throw ArgumentError('EJ receipt range');
    await _waitReady(session);
    final sequence=_sequence;_sequence=_sequence==0x9f?0x20:_sequence+1;
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
      session=await _sessions(connection.endpoint);
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
  int _sequence = 0x20;
  bool _busy = false;
  int? _singleByte(List<int> bytes) => bytes.isEmpty ? null : 1;

  Future<void> _waitReady(ByteSession session) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var authenticated = false;
    while (true) {
      var status = (await session.exchange([9], _singleByte)).single;
      if ((status & 2) != 0 && [0x40, 0x50].contains(status & 0xf0)) {
        throw const TremolPaperRequired();
      }
      if (status == 0x50 && connection.tcpPassword.isEmpty) {
        throw const TremolLanPasswordRequired();
      }
      if (status == 0x50 &&
          !authenticated &&
          connection.tcpPassword.isNotEmpty) {
        authenticated = true;
        status = (await session.exchange([
          ...ascii.encode(connection.tcpPassword),
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
          (connection.model != FiscalModel.tremolM20 && (status & 8) != 0)) {
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

  @override
  String get vendor => 'tremol';

  Future<TremolFrame> _command(
    ByteSession session,
    int command,
    List<int> data, {
    bool ack = false,
  }) async {
    await _waitReady(session);
    final sequence = _sequence;
    _sequence = _sequence == 0x9f ? 0x20 : _sequence + 1;
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
      throw StateError('Tremol rejected command: ${frame.error}');
    }
    if (frame.isAck != ack) {
      throw const FormatException('Unexpected Tremol response type');
    }
    return frame;
  }

  Future<DeviceStatus> _status(ByteSession session) async {
    final frame = await _command(session, 0x20, []);
    if (frame.data.length != 7) {
      throw const FormatException('Expected seven Tremol status bytes');
    }
    final b = frame.data;
    final ready =
        (b[0] & 0x7f) == 0 &&
        (b[1] & 0x07) == 0 &&
        (b[2] & 0x43) == 0 &&
        (b[3] & 0x07) == 0 &&
        (connection.model == FiscalModel.tremolM20 || (b[4] & 0x08) == 0) &&
        (b[5] & 0x33) == 0;
    return DeviceStatus(
      ready: ready,
      details: {
        'paperOut': (b[1] & 1) != 0,
        'dailyReportNonZero': (b[1] & 8) != 0,
        'articleReportNonZero': (b[1] & 16) != 0,
        'operatorReportNonZero': (b[1] & 32) != 0,
        'statusBytes': b.map((value) => value.toRadixString(16).padLeft(2, '0')).join(' '),
      },
      description: (b[1] & 1) != 0
          ? const TremolPaperRequired().toString()
          : ready
          ? 'Tremol pregătit'
          : 'Tremol blocat sau cu document deschis; verifică starea pe ECR',
    );
  }

  @override
  Future<DeviceStatus> readStatus() async {
    if (_busy) {
      return const DeviceStatus(ready: false, description: 'Comandă în curs');
    }
    _busy = true;
    ByteSession? session;
    try {
      session = await _sessions(connection.endpoint);
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
      session = await _sessions(connection.endpoint);
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
      session = await _sessions(connection.endpoint);
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
      session = await _sessions(connection.endpoint);
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
      session = await _sessions(connection.endpoint);
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
      session = await _sessions(connection.endpoint);
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
      session = await _sessions(connection.endpoint);
      await _waitReady(session);
      sent = true;
      final response = await session.exchange(
        TremolProtocol.encode(0x20, command, data), TremolProtocol.frameLength);
      final frame = TremolProtocol.decode(response, sequence: 0x20, command: command);
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
      session = await _sessions(connection.endpoint);
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
    var dispatched = false;
    try {
      session = await _sessions(connection.endpoint);
      if (!(await _status(session)).ready) {
        return const HardwareResult(
          CommandOutcome.rejected,
          message: 'ECR nu este pregătit',
        );
      }
      dispatched = true;
      await _command(
        session,
        0x2e,
        ascii.encode(
          '${connection.operatorNumber};${connection.operatorPassword}',
        ),
        ack: true,
      );
      for (final line in lines) {
        await _command(session, 0x37, ascii.encode(line), ack: true);
      }
      await _command(session, 0x2f, [], ack: true);
      return const HardwareResult(
        CommandOutcome.succeeded,
        message: 'Document nefiscal confirmat de Tremol',
      );
    } catch (_) {
      return HardwareResult(
        dispatched ? CommandOutcome.unknown : CommandOutcome.rejected,
        message: 'Tipărire neconfirmată; verifică documentul pe Tremol',
      );
    } finally {
      await session?.close();
      _busy = false;
    }
  }

  /// Pure preparation, before opening a fiscal document. No command injection,
  /// implicit VAT mapping, price conversion or unsupported discount semantics.
  List<List<int>> prepareLines(FiscalReceipt receipt) => receipt.lines.map((
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

  @override
  Future<HardwareResult> printReceipt(FiscalReceipt receipt) async {
    final lines = prepareLines(receipt);
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
      session = await _sessions(connection.endpoint);
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
      for(final payment in receipt.payments){
        final code=connection.paymentCode(payment.method);
        if(!RegExp(r'^\d$').hasMatch(code))throw ArgumentError('Invalid Tremol tender code');
        await _command(session,0x35,ascii.encode('$code;0;${minorToDecimal(payment.amountMinor)};1'),ack:true);
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
      session=await _sessions(connection.endpoint);
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
