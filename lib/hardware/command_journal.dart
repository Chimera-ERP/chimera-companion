import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'contracts.dart';

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

/// Transport authorization is validated before a new dispatch, not part of
/// the financial command identity. Renewing a lease/proof must not repeat it.
Map<String, Object?> _businessPayload(String operation, Map<String, Object?> payload) {
  if (['xReport','zReport','nonFiscal'].contains(operation)) {
    return Map<String,Object?>.from(payload)..remove('recoveryOnly');
  }
  if (!['fiscalReceipt','cashDeposit','cashWithdraw','payment'].contains(operation)) return payload;
  final value = Map<String,Object?>.from(payload)
    ..remove('checkoutPolicy')..remove('saleAuthorization')
    ..remove('paymentAuthorization')
    ..remove('fidelityAuthorization')
    ..remove('authorizationExpires')..remove('posId')..remove('recoveryOnly');
  // Previous cash/manual-card receipts did not contain this redundant field.
  // Integrated receipts retain it because it binds their payment evidence.
  if(operation=='fiscalReceipt' && value['paymentEvidence']==null) value.remove('saleId');
  return value;
}

/// The journal contains identity hashes and sanitized results, never credentials
/// or payment/card response payloads. Use one app-private file for all devices.
class CommandJournal {
  CommandJournal(this.file);
  final File file;
  static final Set<String> _busyFiles = {};

  static String fingerprint(
    String deviceId,
    String operation,
    Map<String, Object?> payload,
  ) => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            _canonical({
              'device': deviceId,
              'operation': operation,
              'payload': _businessPayload(operation, payload),
            }),
          ),
        ),
      )
      .toString();

  Future<HardwareResult?> lookup({
    required String id,
    required String deviceId,
    required String operation,
    required Map<String, Object?> payload,
  }) async {
    if (!await file.exists()) return null;
    Map<String, dynamic>? found;
    for (final line in const LineSplitter().convert(
      await file.readAsString(),
    )) {
      final value = jsonDecode(line) as Map<String, dynamic>;
      if (value['id'] == id) found = value;
    }
    if (found == null) return null;
    if (found['hash'] != fingerprint(deviceId, operation, payload)) {
      throw StateError('Idempotency key payload mismatch');
    }
    return HardwareResult(
      switch (found['outcome']) {
        'succeeded' => CommandOutcome.succeeded,
        'rejected' => CommandOutcome.rejected,
        _ => CommandOutcome.unknown,
      },
      reference: found['reference'] as String?,
      message: found['message'] as String? ?? 'Rezultat neconfirmat',
      fiscalIdentity: Map<String,String>.from(found['fiscalIdentity'] as Map? ?? {}),
    );
  }

  Future<List<Map<String, dynamic>>> recent({int limit = 30}) async {
    if (!await file.exists()) return [];
    final latest = <String, Map<String, dynamic>>{};
    final lines = const LineSplitter().convert(await file.readAsString());
    for (final line in lines) {
      Map<String, dynamic> entry;
      try {
        entry = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (entry['id'] is! String) continue;
      final id = entry['id'] as String;
      latest[id] = {...?latest[id], ...entry};
    }
    return latest.values
        .toList()
        .reversed
        .take(limit)
        .map(
          (entry) => {
            'id': entry['id'],
            'operation': entry['operation'] ?? 'command',
            'at': entry['at'],
            'outcome': entry['outcome'] == 'in_flight'
                ? 'unknown'
                : entry['outcome'],
            'message':
                entry['message'] ??
                'Comandă neconfirmată; verifică dispozitivul',
            'reference': entry['reference'],
            'deviceId': entry['deviceId'],
          },
        )
        .toList();
  }

  /// Do not use the truncated diagnostic history for a financial safety gate.
  /// A corrupt or oversized journal must fail closed rather than hide uncertainty.
  Future<Map<String,Map<String,dynamic>>> _latestStrict() async {
    if (!await file.exists()) return {};
    if (await file.length() > 16 * 1024 * 1024) {
      throw StateError('Journal requires maintenance before drawer count');
    }
    final latest = <String, Map<String, dynamic>>{};
    for (final line in const LineSplitter().convert(await file.readAsString())) {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic> || value['id'] is! String || value['hash'] is! String) {
        throw const FormatException('Corrupt journal; refusing drawer count');
      }
      final id = value['id'] as String;
      latest[id] = {...?latest[id], ...value};
    }
    return latest;
  }

  Future<bool> hasUnresolvedDrawerEffects(String deviceId) async {
    return (await _latestStrict()).values.any((entry) =>
      entry['deviceId'] == deviceId &&
      ['fiscalReceipt','cashDeposit','cashWithdraw'].contains(entry['operation']) &&
      !['succeeded','rejected'].contains(entry['outcome']));
  }

  /// A sale admission is settled only by its confirmed fiscal result, not by
  /// elapsed time or a rejected print (payment may already have succeeded).
  Future<Set<String>> confirmedReceiptIds(String deviceId) async {
    final latest=await _latestStrict();
    return latest.entries.where((e)=>e.value['deviceId']==deviceId&&e.value['operation']=='fiscalReceipt'&&e.value['outcome']=='succeeded').map((e)=>e.key).toSet();
  }

  /// Command IDs are unique across this Companion's journal, not just the
  /// visible recent page or one currently configured equipment.
  Future<bool> containsCommandId(String id) async {
    return (await _latestStrict()).containsKey(id);
  }

  Future<bool> hasProductionPrint(String id, String deviceId, String operation) async {
    final entry = (await _latestStrict())[id];
    return entry != null && entry['deviceId'] == deviceId &&
      entry['operation'] == operation && operation.startsWith('production');
  }

  /// Only a final adapter rejection proves that this receipt had no effect.
  /// In-flight, unknown, successful and foreign-equipment entries never qualify.
  Future<bool> hasRejectedReceipt(String id, String deviceId) async {
    final entry=(await _latestStrict())[id];
    return entry!=null&&entry['deviceId']==deviceId&&
      entry['operation']=='fiscalReceipt'&&entry['outcome']=='rejected';
  }

  /// A handler's rejection (disabled terminal, queue conflict, invalid proof)
  /// is not evidence of a bank rejection. Only an exact durable payment entry
  /// may attest the terminal result; absence/unknown/corruption cannot release it.
  Future<bool> hasRecordedPaymentRejection({required String id,required String deviceId,
    required Map<String,Object?> payload}) async {
    final entry=(await _latestStrict())[id];
    if(entry==null)return false;
    if(entry['deviceId']!=deviceId||entry['operation']!='payment'||
      entry['hash']!=fingerprint(deviceId,'payment',payload)) {
      throw StateError('Payment rejection identity mismatch');
    }
    return entry['outcome']=='rejected';
  }

  Future<HardwareResult> execute({
    required String id,
    required String deviceId,
    required String operation,
    required Map<String, Object?> payload,
    required Future<HardwareResult> Function() dispatch,
  }) async {
    if (id.isEmpty || deviceId.isEmpty || operation.isEmpty) {
      throw ArgumentError('Missing command identity');
    }
    final fileKey = file.absolute.path;
    if (!_busyFiles.add(fileKey)) {
      return const HardwareResult(
        CommandOutcome.rejected,
        message: 'Companion execută deja o comandă',
      );
    }
    RandomAccessFile? handle;
    var locked = false;
    try {
      await file.parent.create(recursive: true);
      handle = await file.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      locked = true;
      final digest = fingerprint(deviceId, operation, payload);
      if (await handle.length() > 16 * 1024 * 1024) {
        throw StateError('Journal requires maintenance');
      }
      final source = await file.readAsString();
      Map<String, dynamic>? previous;
      final provisionalEntries=<String,Map<String,dynamic>>{};
      for (final line in const LineSplitter().convert(source)) {
        final value = jsonDecode(line);
        if (value is! Map<String, dynamic> ||
            value['id'] is! String ||
            value['hash'] is! String) {
          throw const FormatException(
            'Corrupt journal; refusing hardware dispatch',
          );
        }
        if (value['id'] == id) previous = value;
        if(payload['labelLeaseId']!=null && value['labelLeaseId']==payload['labelLeaseId'] &&
          value['deviceId']==deviceId && value['operation']=='productionLabel') {
          provisionalEntries[value['id'] as String]={...?provisionalEntries[value['id']],...Map<String,dynamic>.from(value)};
        }
        if(operation=='payment' && payload['saleId']!=null &&
            value['operation']=='payment' && value['saleId']==payload['saleId'] &&
            value['receiptCompanionId']==payload['receiptCompanionId'] && value['id']!=id) {
          throw StateError('This sale already has a payment command; recover its original ID');
        }
        if (operation == 'fiscalReceipt' &&
            payload['paymentCommandId'] != null &&
            value['paymentCommandId'] == payload['paymentCommandId'] &&
            value['id'] != id) {
          throw StateError(
            'This payment is already bound to another fiscal command',
          );
        }
      }
      if (previous != null) {
        if (previous['hash'] != digest) {
          throw StateError('Idempotency key reused with a different payload');
        }
        return HardwareResult(
          switch (previous['outcome']) {
            'succeeded' => CommandOutcome.succeeded,
            'rejected' => CommandOutcome.rejected,
            _ => CommandOutcome.unknown,
          },
          reference: previous['reference'] as String?,
          fiscalIdentity: Map<String,String>.from(previous['fiscalIdentity'] as Map? ?? {}),
          message:
              previous['message'] as String? ??
              'Comandă trimisă anterior; necesită verificare',
        );
      }
      if(payload['labelLeaseId']!=null) {
        final max=payload['maxCommands'];
        if(operation!='productionLabel'||max is! int||max<1||max>100||provisionalEntries.length>=max) {
          throw StateError('Provisional output label lease command limit reached');
        }
        final reprint=payload['reprintOf'];
        if(reprint!=null) {
          final original=provisionalEntries[reprint];
          if(original==null || original['reportId']!=payload['reportId'] ||
            original['labelDocumentHash']!=payload['labelDocumentHash']) {
            throw StateError('Reprint must preserve the exact measured output and original lease');
          }
        } else if(provisionalEntries.values.any((entry)=>entry['reportId']==payload['reportId'])) {
          throw StateError('Output report already labelled; explicit auditable reprint required');
        }
      }
      Future<void> append(Map<String, Object?> value) async {
        await handle!.writeString('${jsonEncode(value)}\n');
        await handle.flush();
      }

      final metadata = {
        if (operation.startsWith('production')) ...{
          'reprintOf': payload['reprintOf'],
          'reprintReason': payload['reprintReason'],
          'operationId': payload['operationId'],
          'provisional': payload['provisional'],
          'authorizedActor': payload['authorizedActor'],
          'authorizedDevice': payload['authorizedDevice'],
          if(payload['labelLeaseId']!=null) ...{
            'labelLeaseId':payload['labelLeaseId'],'reportId':payload['reportId'],
            'labelDocumentHash':payload['labelDocumentHash'],
          },
        },
        if(operation=='payment' && payload['saleId']!=null) ...{
          'saleId':payload['saleId'],'receiptCompanionId':payload['receiptCompanionId'],
          'receiptCommandId':payload['receiptCommandId'],
        },
        if (operation == 'fiscalReceipt' && payload['paymentCommandId'] != null)
          'paymentCommandId': payload['paymentCommandId'],
        'operation': operation,
        'deviceId': deviceId,
        'at': DateTime.now().toUtc().toIso8601String(),
      };
      await append({
        'id': id,
        'hash': digest,
        'outcome': 'in_flight',
        ...metadata,
      });
      HardwareResult result;
      try {
        result = await dispatch();
        if(operation=='fiscalReceipt'&&result.outcome==CommandOutcome.succeeded){
          result=HardwareResult(result.outcome,reference:result.reference,message:result.message,
            fiscalIdentity:{...result.fiscalIdentity,'documentMode':payload['documentMode'] as String? ?? 'fiscal','fiscalEmittedAt':DateTime.now().toUtc().toIso8601String()});
        }
      } catch (_) {
        result = const HardwareResult(
          CommandOutcome.unknown,
          message: 'Rezultat hardware incert; nu retrimite',
        );
      }
      await append({
        'id': id,
        'hash': digest,
        'outcome': result.outcome.name,
        'reference': result.reference,
        if (result.fiscalIdentity.isNotEmpty) 'fiscalIdentity':result.fiscalIdentity,
        'message': result.message,
        ...metadata,
      });
      return result;
    } finally {
      if (locked) await handle?.unlock();
      await handle?.close();
      _busyFiles.remove(fileKey);
    }
  }
}
