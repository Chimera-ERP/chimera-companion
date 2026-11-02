import 'connection.dart';
import 'contracts.dart';
import 'datecs_device_client.dart';
import 'datecs_gateway_adapter.dart';
import 'datecs_gateway_protocol.dart';
import 'datecs_rou_adapter.dart';
import 'money.dart';
import 'tcp_transport.dart';
import 'tremol_adapter.dart';
import 'command_journal.dart';
import 'datecs_receipt_recovery.dart';

/// One application contract. Protocol detection never falls back after a write.
class FiscalDevice {
  FiscalDevice(this.connection, {this.profile = DatecsProfile.auto});
  final FiscalConnection connection;
  final DatecsProfile profile;
  Future<void> Function(Map<String,dynamic>)? receiptCheckpoint;
  Future<HardwareResult> reconcileReceipt(String commandId,Map<String,dynamic>? evidence) async {
    if(_tremol)return TremolAdapter(connection).reconcileReceipt(commandId,evidence);
    if(['asciiMx','rouMx'].contains(evidence?['profile']))return DatecsReceiptRecovery.read(connection.endpoint,commandId,evidence);
    return const HardwareResult(CommandOutcome.unknown,message:'Rezultatul Datecs necesită verificare în jurnalul electronic. Bonul nu este retrimis.');
  }
  DatecsProfile? _detectedProfile;
  String get id =>
      '${connection.model.name}:${connection.endpoint.host}:${connection.endpoint.port}';
  String get name => switch (connection.model) {
    FiscalModel.tremolM20 => 'Tremol M20',
    FiscalModel.tremolFp21 => 'Tremol FP21',
    FiscalModel.datecsDp25 => 'Datecs DP-25',
  };
  bool get _tremol => connection.model != FiscalModel.datecsDp25;
  List<String> get capabilities => [
    'status',
    'saleAuthorize',
    'salePaymentStart',
    'salePaymentReject',
    'saleAbandon',
    'saleExternalPaymentConfirm',
    'fiscalPolicy',
    'settlementV2',
    if(_tremol||(_detectedProfile??profile)==DatecsProfile.asciiMx) 'nonFiscalSale',
    if(connection.loyaltyPaymentCode!=null&&(_tremol||(_detectedProfile??profile)==DatecsProfile.asciiMx)) 'loyaltyPayment',
    if(_tremol) ...['buyerTaxId','cashDeposit','cashWithdraw','receiptClaimBarcode'],
    if (_tremol) 'operatorLogin',
    'fiscalReceipt',
    'xReport',
    'zReport',
    if (_tremol || (_detectedProfile ?? profile) == DatecsProfile.asciiMx)
      'nonFiscal',
  ];
  factory FiscalDevice.fromSettings(Map<String, dynamic> data) => FiscalDevice(
    FiscalConnection(
      id: 'local-ecr',
      model: FiscalModel.values.byName(data['model'] as String),
      endpoint: LanEndpoint(
        host: data['host'] as String,
        port: int.parse('${data['port']}'),
      ),
      operatorNumber: int.parse('${data['operator']}'),
      operatorPassword: data['password'] as String,
      tcpPassword: data['tcpPassword'] as String? ?? '',
      cashPaymentCode: data['cashCode'] as String,
      cardPaymentCode: data['cardCode'] as String,
      loyaltyPaymentCode:data['loyaltyPaymentCode'] as String?,
      tillNumber: data['till'] as String? ?? '1',
    ),
    profile: DatecsProfile.values.byName(
      data['datecsProfile'] as String? ?? 'auto',
    ),
  );
  Future<DeviceStatus> readStatus() async {
    if (_tremol) return TremolAdapter(connection).readStatus();
    final state = await DatecsDeviceClient(
      connection.endpoint,
      profile: profile,
    ).inspect();
    _detectedProfile = state.profile;
    return DeviceStatus(ready: state.ready, description: state.description);
  }

  Future<HardwareResult> operatorLogin(String name) async {
    if (!_tremol) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message:
            'Sincronizarea operatorului nu este încă disponibilă pentru acest protocol Datecs.',
      );
    }
    return TremolAdapter(connection).renameConfiguredOperator(name);
  }

  /// Business-level operator lifecycle. Callers never compose fiscal commands.
  Future<Map<String, Object?>> setOperator({
    required String commandId,
    required Map<String, dynamic> identity,
    required bool ending,
    required CommandJournal journal,
    required Future<Map<String, dynamic>?> Function(String) read,
    required Future<void> Function(String, Map<String, dynamic>) write,
  }) async {
    if (!_tremol) {
      return {
        'outcome': 'rejected',
        'message': 'Schimbarea operatorului nu este implementată pentru acest protocol Datecs.',
      };
    }
    return TremolAdapter(connection).setOperator(
      deviceId: id, commandId: commandId, identity: identity, ending: ending,
      journal: journal, read: read, write: write,
    );
  }

  String operatorReadinessMessage = 'Operatorul casei nu corespunde operatorului autentificat.';
  Future<bool> operatorReady(Map<String, dynamic> identity,
      Future<Map<String, dynamic>?> Function(String) read) async {
    if (!_tremol) return true; // Datecs receipt uses its configured operator slot.
    final suffix = CommandJournal.fingerprint(id, 'operatorLogin', {});
    final active = await read('operator_active_$suffix');
    final pending = await read('operator_transition_$suffix');
    if (active?['operatorId'] != identity['operatorId']) {
      operatorReadinessMessage = active?['operatorId'] == null
          ? 'Companion nu are un operator ECR activ confirmat. Reverifică activarea operatorului.'
          : 'Companion are alt operator ECR activ decât cel autentificat. Reverifică schimbul de operator.';
      return false;
    }
    if (active?['closed'] == true || active?['closingId'] != null || pending?['transition'] != null) {
      operatorReadinessMessage = active?['closed'] == true
          ? 'Sesiunea operatorului ECR este închisă în Companion. Reverifică activarea operatorului.'
          : 'Schimbul de operator ECR este neconfirmat în Companion. Recuperează operația originală.';
      return false;
    }
    final actual = await TremolAdapter(connection).readOperatorConfiguration();
    operatorReadinessMessage = 'Numele citit din ECR (${actual['name']}) nu corespunde numelui autorizat (${identity['operatorName']}).';
    return actual['name'] == identity['operatorName'];
  }

  Future<HardwareResult> nonFiscal(List<String> lines) async {
    validateNonFiscalLines(lines);
    if (_tremol) return TremolAdapter(connection).printNonFiscal(lines);
    final state = await DatecsDeviceClient(
      connection.endpoint,
      profile: profile,
    ).inspect();
    if (!state.ready || state.profile != DatecsProfile.asciiMx) {
      return HardwareResult(
        CommandOutcome.rejected,
        message: state.description,
      );
    }
    return DatecsGatewayAdapter(connection.endpoint).printNonFiscal(lines);
  }

  Future<HardwareResult> report({required bool closeDay}) async {
    if (_tremol) {
      return TremolAdapter(connection).printReport(closeDay: closeDay);
    }
    return DatecsDeviceClient(
      connection.endpoint,
      profile: profile,
    ).printReport(closeDay: closeDay);
  }

  Future<Map<String,double>> readVatRates() async {
    if(!_tremol)throw ArgumentError('VAT rate discovery not qualified for Datecs');
    return TremolAdapter(connection).readVatRates();
  }

  Future<HardwareResult> receipt(FiscalReceipt receipt) async {
    if(receipt.documentMode=='nonfiscal')return nonFiscalSale(receipt);
    if(!_tremol&&receipt.claimToken!=null)return const HardwareResult(CommandOutcome.rejected,message:'Codul de fidelitate nu este implementat pentru acest adaptor Datecs');
    if(!_tremol && receipt.cui!=null)return const HardwareResult(CommandOutcome.rejected,message:'CUI fiscal nu este încă implementat pentru acest model Datecs');
    if (_tremol) return TremolAdapter(connection,checkpoint:receiptCheckpoint).printReceipt(receipt);
    final state = await DatecsDeviceClient(
      connection.endpoint,
      profile: profile,
    ).inspect();
    if (!state.ready) {
      return HardwareResult(
        CommandOutcome.rejected,
        message: state.description,
      );
    }
    if (state.profile == DatecsProfile.legacyRou) {
      if(receipt.payments.length!=1||receipt.paymentMethod==FiscalPaymentMethod.loyalty)return const HardwareResult(CommandOutcome.rejected,message:'Plățile compuse nu sunt validate pentru acest profil Datecs.');
      return DatecsRouAdapter(connection).printReceipt(receipt);
    }
    if (state.profile != DatecsProfile.asciiMx) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Protocol Datecs neidentificat',
      );
    }
    return DatecsMxFiscalAdapter(connection,checkpoint:receiptCheckpoint).printReceipt(receipt);
  }
  Future<HardwareResult> nonFiscalSale(FiscalReceipt receipt) async {
    final lines=<String>['DOCUMENT NEFISCAL',...receipt.lines.map((l)=>'${l.name.replaceAll(RegExp(r"[^ -~]"),"?").substring(0,l.name.length>24?24:l.name.length)} x ${l.quantityDecimal}'),...receipt.lines.map((l)=>'  ${minorToDecimal(l.grossTotalMinor)} RON'),'TOTAL ${minorToDecimal(receipt.totalMinor)} RON',...receipt.payments.map((p)=>'${p.method.name.toUpperCase()} ${minorToDecimal(p.amountMinor)} RON'),if(receipt.claimToken!=null)'Fidelity: ${receipt.claimToken}'];
    if(lines.any((l)=>l.length>40))throw ArgumentError('Non fiscal receipt line too long');
    HardwareResult result;
    if(_tremol){result=await TremolAdapter(connection).printNonFiscal(lines);}
    else{final state=await DatecsDeviceClient(connection.endpoint,profile:profile).inspect();if(!state.ready||state.profile!=DatecsProfile.asciiMx)return HardwareResult(CommandOutcome.rejected,message:state.description);result=await DatecsGatewayAdapter(connection.endpoint).printNonFiscal(lines,claimToken:receipt.claimToken);}
    return HardwareResult(result.outcome,reference:result.reference,message:result.message,fiscalIdentity:{...result.fiscalIdentity,'documentMode':'nonfiscal'});
  }

  Future<HardwareResult> cashMovement(CashMovementRequest movement) async {
    if(!_tremol)return const HardwareResult(CommandOutcome.rejected,message:'Mișcările de numerar nu sunt încă implementate pentru acest model Datecs');
    return TremolAdapter(connection).cashMovement(movement);
  }
}

void validateNonFiscalLines(List<String> lines) {
  if (lines.isEmpty ||
      lines.length > 100 ||
      lines.any(
        (line) =>
            line.length > 40 || line.codeUnits.any((b) => b < 32 || b > 126),
      )) {
    throw ArgumentError('Maximum 100 lines of 40 printable ASCII characters');
  }
}

/// DATECS MX: common framing; Romanian 2017 and Bulgarian response schemas.
class DatecsMxFiscalAdapter {
  DatecsMxFiscalAdapter(this.connection, {SessionFactory? sessions, this.checkpoint})
    : _sessions = sessions ?? TcpByteSession.connect;
  final FiscalConnection connection;
  final SessionFactory _sessions;
  final Future<void> Function(Map<String,dynamic>)? checkpoint;
  Future<HardwareResult> printReceipt(FiscalReceipt receipt) async {
    if (receipt.payments.any((p)=>!RegExp(r'^[0-5]$').hasMatch(connection.paymentCode(p.method)))) {
      throw ArgumentError('Numeric Datecs MX payment code required');
    }
    for (final line in receipt.lines) {
      if (!RegExp(r'^[A-H]$').hasMatch(line.vatGroup) ||
          line.name.length > 30 ||
          line.name.codeUnits.any((b) => b < 32 || b > 126) ||
          !RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(line.quantityDecimal)) {
        throw ArgumentError('Unsupported Datecs MX line');
      }
    }
    ByteSession? session;
    var dispatched = false;
    try {
      session = await _sessions(connection.endpoint);
      Future<List<String>> send(int command, String payload) async {
        final seq = DatecsGatewayProtocol.nextSequence(
          '${connection.endpoint.host}:${connection.endpoint.port}',
        );
        return DatecsGatewayProtocol.decode(
          await session!.exchange(
            DatecsGatewayProtocol.encode(command, payload, sequence: seq),
            DatecsGatewayProtocol.frameLength,
          ),
          sequence: seq,
          command: command,
        );
      }

      final current = await send(76, '');
      if (current.length < 2 || current[1] != '0') {
        return const HardwareResult(
          CommandOutcome.rejected,
          message: 'Document deja deschis pe Datecs',
        );
      }
      final (serial, fiscalSerial) = await DatecsReceiptRecovery.identity(send);
      final evidence = <String,dynamic>{'profile':'asciiMx','commandId':receipt.commandId,'serialNumber':serial,'fiscalSerialNumber':fiscalSerial};
      await checkpoint?.call(evidence);
      dispatched = true;
      final opened = await send(
        48,
        '${connection.operatorNumber}\t${connection.operatorPassword}\t${connection.tillNumber}\t\t',
      );
      if(![2,4].contains(opened.length)||!DatecsReceiptRecovery.number(opened[1],99999999))throw const FormatException('Receipt number missing');
      evidence['receiptNumber']=opened[1];
      if(opened.length==4){
        if(!DatecsReceiptRecovery.number(opened[2],2500)||!RegExp(r'^[0-9]{1,4}$').hasMatch(opened[3]))throw const FormatException('Romanian receipt identity missing');
        evidence['profile']='rouMx';
        evidence['zNumber']=opened[2];
      }
      await checkpoint?.call(evidence);
      for (final line in receipt.lines) {
        await send(
          49,
          '${line.name}\t${line.vatGroup.codeUnitAt(0) - 64}\t${minorToDecimal(line.unitPriceMinor)}\t${line.quantityDecimal}\t0\t\t0\t',
        );
      }
      final subtotal = await send(51, '0\t0\t0\t\t');
      if (subtotal.length < 3 ||
          decimalToMinor(subtotal[2]) != receipt.totalMinor) {
        throw StateError('Subtotal differs');
      }
      for(final marker in DatecsReceiptRecovery.markers(receipt.commandId)) {
        // RO: keep separators for optional style/alignment fields, including
        // the final reserved field documented by FP_Protocol_RO command54.
        await send(54,evidence['profile']=='rouMx'?'$marker\t\t\t\t\t\t\t':'$marker\t');
      }
      var remaining=receipt.totalMinor;
      for(final tender in receipt.payments){
        final payment=await send(53,'${connection.paymentCode(tender.method)}\t${minorToDecimal(tender.amountMinor)}\t');
        remaining-=tender.amountMinor;
        if(payment.length<3||decimalToMinor(payment[2])!=remaining||(remaining==0&&payment[1]!='R'))throw StateError('Payment not confirmed');
      }
      // Persist before dispatch: a lost close ACK can be reconciled by exact EJ identity.
      evidence['closeAttempted']=true;
      await checkpoint?.call(evidence);
      final closed = await send(56, '');
      if (![2,4].contains(closed.length) || closed[1] != opened[1] ||
          (evidence['profile']=='rouMx' && (closed.length!=4 || closed[2]!=evidence['zNumber'])) ||
          (closed.length==4 && (!DatecsReceiptRecovery.number(closed[2],2500)||!DatecsReceiptRecovery.number(closed[3],9999)))) {
        throw const FormatException('Receipt identity missing');
      }
      // RO nFNum is the fiscal number in nZrep, not the global SlipNumber.
      final identity=<String,String>{'serialNumber':serial,'fiscalSerialNumber':fiscalSerial,
        'documentNumber':closed[1], 'receiptNumber':closed.length==4?closed[3]:closed[1],
        if(closed.length==4)'zNumber':closed[2]};
      await checkpoint?.call({...evidence,'closed':true,'fiscalIdentity':identity});
      return HardwareResult(
        CommandOutcome.succeeded,
        reference: identity['receiptNumber'],
        fiscalIdentity: identity,
        message: 'Bon confirmat de Datecs',
      );
    } catch (_) {
      return HardwareResult(
        dispatched ? CommandOutcome.unknown : CommandOutcome.rejected,
        message: dispatched
            ? 'Rezultat incert; verifică documentul pe Datecs înainte de orice altă vânzare.'
            : 'Datecs indisponibil',
      );
    } finally {
      await session?.close();
    }
  }
}
