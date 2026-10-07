import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'dart:io';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/tcp_transport.dart';
import 'package:chimera_companion/hardware/tremol_adapter.dart';

class PasswordSession implements ByteSession {
  final requests = <List<int>>[];
  bool closed = false;
  @override
  Future<List<int>> exchange(
    List<int> request,
    int? Function(List<int>) length,
  ) async {
    requests.add(request);
    return [0x50];
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class PaperSession extends PasswordSession {
  PaperSession(this.status);
  final int status;
  @override
  Future<List<int>> exchange(List<int> request, int? Function(List<int>) length) async {
    requests.add(request);
    return [status];
  }
}

FiscalConnection connection({String password = '', bool discovery = true}) =>
    FiscalConnection(
      id: 'test',
      model: FiscalModel.tremolM20,
      endpoint: LanEndpoint(host: '192.168.1.172', port: 8000),
      operatorNumber: 1,
      operatorPassword: '',
      tcpPassword: password,
      cashPaymentCode: '0',
      cardPaymentCode: '1',
      allowUnknownOperatorPassword: discovery,
    );

void main() {
  for (final status in [0x42, 0x43, 0x52]) {
    test('paper exhaustion $status is structured and does not dispatch a document', () async {
      final session = PaperSession(status);
      final result = await TremolAdapter(connection(), sessions: (_) async => session).readStatus();
      expect(result.ready, isFalse);
      expect(result.details['paperOut'], isTrue);
      expect(result.description, contains('Lipsă hârtie ECR'));
      expect(session.requests, [[9]]);
      expect(session.closed, isTrue);
    });
  }
  for (final error in [const SocketException('refused'), TimeoutException('timeout')]) {
    test('operator verification identifies unreachable ECR: ${error.runtimeType}', () async {
      final adapter = TremolAdapter(connection(), sessions: (_) async => throw error);
      final result = await adapter.renameConfiguredOperator('Test');
      expect(result.outcome, CommandOutcome.rejected);
      expect(result.message, contains('oprită sau inaccesibilă'));
    });
  }
  test('operator verification identifies LAN password requirement', () async {
    final session = PasswordSession();
    final result = await TremolAdapter(connection(), sessions: (_) async => session).renameConfiguredOperator('Test');
    expect(result.outcome, CommandOutcome.rejected);
    expect(result.message, contains('parola conexiunii LAN'));
    expect(session.requests, [[9]]);
    expect(session.closed, isTrue);
  });
  test('unknown operator password is allowed only for explicit discovery', () {
    expect(() => connection(discovery: false), throwsArgumentError);
    expect(connection().operatorPassword, isEmpty);
  });
  for (final password in ['', 'example']) {
    test(
      'LAN challenge is explicit and does not send fiscal commands (${password.isEmpty})',
      () async {
        final session = PasswordSession();
        final adapter = TremolAdapter(
          connection(password: password),
          sessions: (_) async => session,
        );
        await expectLater(
          adapter.readStatus(),
          throwsA(
            isA<TremolLanPasswordRequired>().having(
              (e) => e.rejected,
              'rejected',
              password.isNotEmpty,
            ),
          ),
        );
        expect(session.requests.length, password.isEmpty ? 1 : 2);
        expect(session.requests.first, [9]);
        expect(session.closed, isTrue);
      },
    );
  }
}
