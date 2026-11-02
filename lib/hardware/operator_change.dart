import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'command_journal.dart';
import 'contracts.dart';

/// Confirmation and durable per-step execution, shared by API callers.
class OperatorChange {
  OperatorChange({
    required this.journal,
    required this.read,
    required this.write,
    required this.state,
    required this.rename,
    required this.reset,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final CommandJournal journal;
  final Future<Map<String, dynamic>?> Function(String) read;
  final Future<void> Function(String, Map<String, dynamic>) write;
  final Future<Map<String, String>> Function() state;
  final Future<HardwareResult> Function(String) rename;
  final Future<HardwareResult> Function() reset;
  final DateTime Function() now;
  String sessionKey(String device) => 'operator_active_${CommandJournal.fingerprint(device, 'operatorLogin', {})}';
  Map<String, Object?> result(HardwareResult value) => {
    'outcome': value.outcome.name,
    'message': value.message,
    'reference': value.reference,
  };

  /// Login only programs the incoming operator. Reports belong to shift exit.
  Future<Map<String, Object?>> login(String device, String id, Map<String, dynamic> payload) async {
    final identity = {'operatorId': payload['operatorId'], 'operatorName': payload['operatorName']};
    return result(await journal.execute(id: '$id-login-only', deviceId: device,
      operation: 'operatorRename', payload: identity,
      dispatch: () => rename(payload['operatorName'] as String)));
  }

  Future<Map<String, Object?>> logout(String device, String id, Map<String, dynamic> payload) async {
    final identity = {'operatorId': payload['operatorId'], 'operatorName': payload['operatorName'],
      if(payload['shiftClose']!=null)'shiftClose':payload['shiftClose']};
    final previous = await journal.lookup(id: id, deviceId: device,
      operation: 'operatorLogout', payload: identity);
    final active = await read(sessionKey(device));
    if (previous != null && active?['closingId'] != id) return result(previous);
    final transition = await read('operator_transition_${CommandJournal.fingerprint(device, 'operatorLogin', {})}');
    if (transition?['transition'] != null) {
      return {'outcome': 'unknown', 'message': 'Schimbarea operatorului este nefinalizată. Verifică jurnalul ECR.'};
    }
    if (active?['closingId'] != null && active!['closingId'] != id) {
      return {'outcome': 'unknown', 'message': 'Închiderea operatorului este neconfirmată. Verifică jurnalul ECR.'};
    }
    if (active?['operatorId'] != null && active!['operatorId'] != identity['operatorId']) {
      return {'outcome': 'rejected', 'message': 'Alt operator este activ pe casa de marcat.'};
    }
    if (active?['closed'] == true) return {'outcome': 'succeeded', 'message': 'Operator deja închis.'};
    await write(sessionKey(device), {...?active, ...identity, 'closingId': id});
    final report = previous ?? await journal.execute(id: id, deviceId: device,
      operation: 'operatorLogout', payload: identity, dispatch: reset);
    if (report.outcome == CommandOutcome.succeeded) {
      await write(sessionKey(device), {...identity, 'closed': true});
    } else if (report.outcome == CommandOutcome.rejected) {
      await write(sessionKey(device), active ?? {});
    }
    return result(report);
  }

  /// Called only after the normal operatorLogin authorization. The all-operator
  /// operator report is part of switching operators, never a daily Z report.
  Future<Map<String, Object?>> runAutomatic(
    String device,
    String id,
    Map<String, dynamic> payload,
  ) async {
    final name = payload['operatorName'] as String;
    final identity = {'operatorId': payload['operatorId'], 'operatorName': name};
    final key = 'operator_transition_${CommandJournal.fingerprint(device, 'operatorLogin', {})}';
    final completed = await journal.lookup(id: '$id-auto-rename', deviceId: device,
        operation: 'operatorRename', payload: identity);
    var pending = await read(key);
    final active = await read(sessionKey(device));
    if (active?['closingId'] != null) {
      return {'outcome': 'unknown', 'message': 'Închiderea operatorului precedent este neconfirmată. Verifică jurnalul ECR.'};
    }
    if (completed != null) {
      if (completed.outcome == CommandOutcome.succeeded && pending?['lastRenameId'] == id) {
        await write(sessionKey(device), identity);
        await write(key, {});
      }
      return {...result(completed), 'operatorReportCompleted': true};
    }
    if (pending?['transition'] != null &&
        (pending!['operatorId'] != identity['operatorId'] || pending['operatorName'] != name)) {
      return {'outcome': 'rejected', 'message': 'Schimbarea precedentă a operatorului este nefinalizată. Verifică jurnalul ECR înainte de alt operator.'};
    }
    if (pending?['lastRenameId'] != null) {
      final prior = await journal.lookup(id: '${pending!['lastRenameId']}-auto-rename',
          deviceId: device, operation: 'operatorRename', payload: identity);
      if (prior?.outcome == CommandOutcome.unknown) return result(prior!);
      if (prior?.outcome == CommandOutcome.succeeded) {
        await write(sessionKey(device), identity);
        await write(key, {});
        return result(prior!);
      }
    }
    if (pending?['transition'] == null) {
      Map<String, String> observed;
      try { observed = await state(); }
      on SocketException { return {'outcome': 'rejected', 'message': 'Casa de marcat nu răspunde: poate fi oprită sau inaccesibilă în rețea. Verifică alimentarea și conexiunea LAN.'}; }
      on TimeoutException { return {'outcome': 'rejected', 'message': 'Casa de marcat nu a răspuns la timp. Verifică alimentarea și conexiunea LAN.'}; }
      if (observed['name'] == name && active?['closed'] != true &&
          (active?['operatorId'] == null || active?['operatorId'] == identity['operatorId'])) {
        await write(sessionKey(device), identity);
        return {'outcome': 'succeeded', 'message': 'Operator ECR: $name'};
      }
      pending = {...identity, 'transition': id, 'alreadyClosed': active?['closed'] == true};
      await write(key, pending);
    }
    // Preserve uncertain legacy executions; never turn an upgrade into a retry.
    // A confirmed old scoped report does not certify that all operators were reset.
    final legacyReport = await journal.lookup(
      id: '${pending!['transition']}-auto-report', deviceId: device,
      operation: 'operatorReportReset', payload: identity,
    );
    if (legacyReport?.outcome == CommandOutcome.unknown) {
      return result(legacyReport!);
    }
    final report = pending['alreadyClosed'] == true
        ? const HardwareResult(CommandOutcome.succeeded, message: 'Operator deja închis')
        : await journal.execute(
      id: '${pending['transition']}-auto-report-all', deviceId: device,
      operation: 'operatorReportReset', payload: identity, dispatch: reset,
    );
    if (report.outcome != CommandOutcome.succeeded) {
      // Unknown stays pending across restart/new command IDs: never repeat it.
      if (report.outcome == CommandOutcome.rejected) await write(key, {});
      return result(report);
    }
    await write(key, {...pending, 'lastRenameId': id});
    final changed = await journal.execute(
      id: '$id-auto-rename', deviceId: device,
      operation: 'operatorRename', payload: identity, dispatch: () => rename(name),
    );
    if (changed.outcome == CommandOutcome.succeeded) {
      await write(sessionKey(device), identity);
      await write(key, {});
    }
    return {...result(changed), 'operatorReportCompleted': true};
  }

  Future<Map<String, Object?>> run(
    String device,
    String id,
    Map<String, dynamic> payload,
  ) async {
    final name = payload['operatorName'] as String;
    final identity = {
      'operatorId': payload['operatorId'],
      'operatorName': name,
    };
    final confirmation = payload['confirmationId'];
    if (confirmation == null) {
      final attempt = await journal.execute(
        id: id,
        deviceId: device,
        operation: 'operatorLogin',
        payload: identity,
        dispatch: () => rename(name),
      );
      if (attempt.reference != 'operator_report_required') {
        return result(attempt);
      }
      if (payload['canResetOperatorReport'] != true) {
        return {
          'outcome': 'rejected',
          'message':
              'Golirea raportului operatorului necesită permisiune de administrare ECR sau închidere de casă.',
        };
      }
      final observed = await state();
      final token = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await write('operator_confirmation_$token', {
        'device': device,
        ...identity,
        'state': observed,
        'expires': now().add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      });
      return {
        'outcome': 'requires_confirmation',
        'confirmationId': token,
        'message':
            'Se tipărește raportul cu golire pentru TOȚI operatorii și se golesc acumulările tuturor. Nu se emite Z fiscal zilnic.',
        'previousOperator': observed['name'],
        'nextOperator': name,
      };
    }
    if (confirmation is! String ||
        !RegExp(r'^[0-9a-f]{48}$').hasMatch(confirmation) ||
        payload['confirmOperatorReport'] != true) {
      throw ArgumentError('Explicit operator report confirmation required');
    }
    final ticket = await read('operator_confirmation_$confirmation');
    if (ticket == null ||
        ticket['device'] != device ||
        ticket['operatorId'] != identity['operatorId'] ||
        ticket['operatorName'] != name) {
      return {
        'outcome': 'rejected',
        'message': 'Confirmarea aparține altei operațiuni sau altui operator.',
      };
    }
    final stepId = 'operator-confirm-$confirmation';
    final stepPayload = {'confirmation': confirmation, ...identity};
    var report = await journal.lookup(
      id: '$stepId-report',
      deviceId: device,
      operation: 'operatorReportReset',
      payload: stepPayload,
    );
    if (report == null) {
      if (payload['canResetOperatorReport'] != true ||
          (ticket['expires'] as int) <= now().millisecondsSinceEpoch) {
        return {
          'outcome': 'rejected',
          'message': 'Confirmarea a expirat sau operatorul nu are permisiune.',
        };
      }
      if (jsonEncode(await state()) != jsonEncode(ticket['state'])) {
        return {
          'outcome': 'rejected',
          'message':
              'Starea ECR s-a schimbat. Reia sincronizarea și confirmă starea actuală.',
        };
      }
      report = await journal.execute(
        id: '$stepId-report',
        deviceId: device,
        operation: 'operatorReportReset',
        payload: stepPayload,
        dispatch: reset,
      );
    }
    if (report.outcome != CommandOutcome.succeeded) return result(report);
    final changed = await journal.execute(
      id: '$stepId-rename-$id',
      deviceId: device,
      operation: 'operatorRename',
      payload: stepPayload,
      dispatch: () => rename(name),
    );
    return {...result(changed), 'operatorReportCompleted': true};
  }
}
