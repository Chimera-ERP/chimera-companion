import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/operator_change.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/contracts.dart';

void main() {
  late Directory dir;
  late CommandJournal journal;
  late Map<String, Map<String, dynamic>> tickets;
  var reportCount = 0, renameCount = 0;
  var current = 'Bob';
  var counter = '3';
  var renameFails = false;
  var reportUnknown = false;
  var renameUnknown = false;
  final payload = <String, dynamic>{
    'operatorId': 'admin-id',
    'operatorName': 'admin',
    'canResetOperatorReport': true,
  };
  OperatorChange workflow() => OperatorChange(
    journal: journal,
    read: (key) async => tickets[key],
    write: (key, value) async {
      tickets[key] = value;
    },
    state: () async => {'name': current, 'counters': counter},
    rename: (name) async {
      renameCount++;
      if (renameUnknown) return const HardwareResult(CommandOutcome.unknown, message: 'Lost rename response');
      if (counter != '0') {
        return const HardwareResult(
          CommandOutcome.rejected,
          reference: 'operator_report_required',
          message: 'Required',
        );
      }
      if (renameFails) {
        return const HardwareResult(
          CommandOutcome.rejected,
          message: 'Connection failed',
        );
      }
      current = name;
      return const HardwareResult(CommandOutcome.succeeded, message: 'Changed');
    },
    reset: () async {
      reportCount++;
      if (reportUnknown) return const HardwareResult(CommandOutcome.unknown, message: 'Lost response');
      counter = '0';
      return const HardwareResult(CommandOutcome.succeeded, message: 'Report');
    },
  );
  Future<Map<String, dynamic>> confirm() async {
    final reply = await workflow().run('ecr', 'login', payload);
    expect(reply['outcome'], 'requires_confirmation');
    expect(reportCount, 0);
    return {
      ...payload,
      'confirmationId': reply['confirmationId'],
      'confirmOperatorReport': true,
    };
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('operator-change-test-');
    journal = CommandJournal(File('${dir.path}/journal'));
    tickets = {};
    reportCount = 0;
    renameCount = 0;
    current = 'Bob';
    counter = '3';
    renameFails = false;
    reportUnknown = false;
    renameUnknown = false;
  });
  tearDown(() async => dir.delete(recursive: true));
  test('login never resets totals, logout resets exactly once then login renames', () async {
    expect((await workflow().login('ecr','first',payload))['outcome'],'rejected');
    expect(reportCount,0);
    expect((await workflow().logout('ecr','exit',payload))['outcome'],'succeeded');
    await workflow().logout('ecr','exit',payload);
    expect(reportCount,1);
    expect((await workflow().login('ecr','second',payload))['outcome'],'succeeded');
    expect(reportCount,1);
    expect(current,'admin');
  });
  test('uncertain logout is not reset again after restart', () async {
    reportUnknown=true;
    expect((await workflow().logout('ecr','exit',payload))['outcome'],'unknown');
    journal=CommandJournal(File('${dir.path}/journal'));
    await workflow().logout('ecr','exit',payload);
    expect(reportCount,1);
  });
  test('offline closure evidence cannot be replayed with changed counts',()async{
    final count={...payload,'shiftClose':{'shiftId':'shift','denominations':{'100':1}}};
    expect((await workflow().logout('ecr','shift-close-shift',count))['outcome'],'succeeded');
    journal=CommandJournal(File('${dir.path}/journal'));
    await workflow().logout('ecr','shift-close-shift',count);
    await expectLater(workflow().logout('ecr','shift-close-shift',{...payload,'shiftClose':{'shiftId':'shift','denominations':{'100':2}}}),throwsStateError);
    expect(reportCount,1);
  });
  for (final outcome in [CommandOutcome.succeeded, CommandOutcome.unknown]) {
    test('legacy scoped report ${outcome.name} migration preserves uncertainty', () async {
      final identity = {'operatorId': 'admin-id', 'operatorName': 'admin'};
      final key = 'operator_transition_${CommandJournal.fingerprint('ecr', 'operatorLogin', {})}';
      tickets[key] = {...identity, 'transition': 'old'};
      await journal.execute(id: 'old-auto-report', deviceId: 'ecr',
        operation: 'operatorReportReset', payload: identity,
        dispatch: () async => HardwareResult(outcome, message: 'Legacy'));
      final reply = await workflow().runAutomatic('ecr', 'new', payload);
      expect(reply['outcome'], outcome.name);
      expect(reportCount, outcome == CommandOutcome.succeeded ? 1 : 0);
      expect(renameCount, outcome == CommandOutcome.succeeded ? 1 : 0);
      await workflow().runAutomatic('ecr', 'retry', payload);
      expect(reportCount, outcome == CommandOutcome.succeeded ? 1 : 0);
    });
  }
  test('automatic operator switch reports before rename without daily-close permission', () async {
    final next = {...payload, 'canResetOperatorReport': false};
    expect((await workflow().runAutomatic('ecr', 'auto', next))['outcome'], 'succeeded');
    expect(current, 'admin');
    expect(reportCount, 1);
    expect(renameCount, 1);
    await workflow().runAutomatic('ecr', 'auto', next);
    await workflow().runAutomatic('ecr', 'another-login', next);
    expect(reportCount, 1);
  });
  test('automatic switch resumes rename after restart without a second report', () async {
    renameFails = true;
    expect((await workflow().runAutomatic('ecr', 'auto', payload))['operatorReportCompleted'], true);
    journal = CommandJournal(File('${dir.path}/journal'));
    renameFails = false;
    expect((await workflow().runAutomatic('ecr', 'retry', payload))['outcome'], 'succeeded');
    expect(reportCount, 1);
  });
  test('uncertain report survives restart/new ID and blocks another operator', () async {
    reportUnknown = true;
    expect((await workflow().runAutomatic('ecr', 'auto', payload))['outcome'], 'unknown');
    journal = CommandJournal(File('${dir.path}/journal'));
    expect((await workflow().runAutomatic('ecr', 'retry', payload))['outcome'], 'unknown');
    expect((await workflow().runAutomatic('ecr', 'other', {...payload, 'operatorId': 'other'}))['outcome'], 'rejected');
    expect(reportCount, 1);
    expect(renameCount, 0);
  });
  test('same operator produces no report or rename', () async {
    current = 'admin';
    expect((await workflow().runAutomatic('ecr', 'same', payload))['outcome'], 'succeeded');
    expect(reportCount, 0);
    expect(renameCount, 0);
  });
  test('restart after successful rename clears the unfinished transition', () async {
    await workflow().runAutomatic('ecr', 'auto', payload);
    final key = tickets.keys.firstWhere((key) => key.startsWith('operator_transition_'));
    tickets[key] = {'transition': 'auto', 'lastRenameId': 'auto',
      'operatorId': payload['operatorId'], 'operatorName': payload['operatorName']};
    await workflow().runAutomatic('ecr', 'auto', payload);
    expect(tickets[key], isEmpty);
    expect(reportCount, 1);
  });
  test('lock then another operator, including identical display names, closes and changes once', () async {
    current = 'admin';
    await workflow().runAutomatic('ecr', 'initial', payload);
    journal = CommandJournal(File('${dir.path}/journal'));
    await workflow().runAutomatic('ecr', 'unlock', payload);
    expect(reportCount, 0);
    final other = {...payload, 'operatorId': 'different-id'};
    await workflow().runAutomatic('ecr', 'other-login', other);
    expect(reportCount, 1);
    expect(renameCount, 1);
    await workflow().runAutomatic('ecr', 'other-login', other);
    expect(reportCount, 1);
  });
  test('explicit logout then new operator does not print a second report', () async {
    current = 'admin';
    await workflow().runAutomatic('ecr', 'initial', payload);
    await workflow().logout('ecr', 'exit', payload);
    await workflow().runAutomatic('ecr', 'next', {...payload, 'operatorId': 'new', 'operatorName': 'Alice'});
    expect(reportCount, 1);
    expect(current, 'Alice');
  });
  test('unknown logout blocks incoming operator even after restart', () async {
    current = 'admin';
    await workflow().runAutomatic('ecr', 'initial', payload);
    reportUnknown = true;
    await workflow().logout('ecr', 'exit', payload);
    journal = CommandJournal(File('${dir.path}/journal'));
    expect((await workflow().runAutomatic('ecr', 'next', {...payload, 'operatorId': 'new'}))['outcome'], 'unknown');
    expect(reportCount, 1);
    expect(renameCount, 0);
  });
  test('unknown rename is not repeated under a new command after restart', () async {
    renameUnknown = true;
    expect((await workflow().runAutomatic('ecr', 'first', payload))['outcome'], 'unknown');
    journal = CommandJournal(File('${dir.path}/journal'));
    expect((await workflow().runAutomatic('ecr', 'retry', payload))['outcome'], 'unknown');
    expect((await workflow().logout('ecr', 'exit', payload))['outcome'], 'unknown');
    expect(reportCount, 1);
    expect(renameCount, 1);
  });
  test(
    'confirmation executes scoped report once; duplicate and restart never zero again',
    () async {
      final approved = await confirm();
      expect(
        (await workflow().run('ecr', 'confirmed', approved))['outcome'],
        'succeeded',
      );
      expect(current, 'admin');
      await workflow().run('ecr', 'confirmed', approved);
      expect(reportCount, 1);
      expect(renameCount, 2);
    },
  );
  test('changed state invalidates confirmation before report', () async {
    final approved = await confirm();
    counter = '4';
    expect(
      (await workflow().run('ecr', 'confirmed', approved))['outcome'],
      'rejected',
    );
    expect(reportCount, 0);
  });
  test('confirmation cannot cross devices or operators', () async {
    final approved = await confirm();
    expect(
      (await workflow().run('other-ecr', 'confirmed', approved))['outcome'],
      'rejected',
    );
    expect(
      (await workflow().run('ecr', 'confirmed', {
        ...approved,
        'operatorId': 'other',
      }))['outcome'],
      'rejected',
    );
    expect(reportCount, 0);
  });
  test('partial failure resumes rename without a second report', () async {
    final approved = await confirm();
    renameFails = true;
    final first = await workflow().run('ecr', 'confirmed', approved);
    expect(first['operatorReportCompleted'], true);
    renameFails = false;
    expect(
      (await workflow().run('ecr', 'rename-retry', approved))['outcome'],
      'succeeded',
    );
    expect(reportCount, 1);
  });
  test('no reset permission never offers destructive confirmation', () async {
    expect(
      (await workflow().run('ecr', 'login', {
        ...payload,
        'canResetOperatorReport': false,
      }))['outcome'],
      'rejected',
    );
    expect(tickets, isEmpty);
    expect(reportCount, 0);
  });
  test('expiry refuses report', () async {
    final approved = await confirm();
    tickets.values.single['expires'] = 0;
    expect(
      (await workflow().run('ecr', 'confirmed', approved))['outcome'],
      'rejected',
    );
    expect(reportCount, 0);
  });
}
