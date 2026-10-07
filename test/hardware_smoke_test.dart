// Opt-in LAN smoke. No fiscal receipt, payment or Z is emitted by this test.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/fiscal_device.dart';
import 'package:chimera_companion/hardware/datecs_device_client.dart';
import 'package:chimera_companion/hardware/tcp_transport.dart';
import 'package:chimera_companion/hardware/tremol_protocol.dart';

void main() {
  test(
    'unified facade reads both real ECRs and optionally prints non-fiscal',
    () async {
      final e = Platform.environment;
      final tremolEndpoint = LanEndpoint(host: e['TREMOL_HOST']!, port: 8000);
      final session = await TcpByteSession.connect(tremolEndpoint);
      String operatorPassword;
      try {
        final status = await session.exchange([9], (b) => b.isEmpty ? null : 1);
        if (status.single == 0x50) {
          await session.exchange([
            ...ascii.encode(e['TREMOL_TCP_PASSWORD']!),
            10,
            9,
          ], (b) => b.isEmpty ? null : 1);
        }
        final reply = TremolProtocol.decode(
          await session.exchange(
            TremolProtocol.encode(0x27, 0x6a, ascii.encode('1')),
            TremolProtocol.frameLength,
          ),
          sequence: 0x27,
          command: 0x6a,
        );
        expect(reply.error, isNull);
        operatorPassword = latin1.decode(reply.data).split(';')[2];
      } finally {
        await session.close();
      }
      final devices = [
        FiscalDevice(
          FiscalConnection(
            id: 'tremol',
            model: FiscalModel.tremolM20,
            endpoint: tremolEndpoint,
            operatorNumber: 1,
            operatorPassword: operatorPassword,
            tcpPassword: e['TREMOL_TCP_PASSWORD']!,
            cashPaymentCode: '0',
            cardPaymentCode: '1',
          ),
        ),
        FiscalDevice(
          FiscalConnection(
            id: 'datecs',
            model: FiscalModel.datecsDp25,
            endpoint: LanEndpoint(host: e['DATECS_HOST']!, port: 3999),
            operatorNumber: 1,
            operatorPassword: '0001',
            cashPaymentCode: '0',
            cardPaymentCode: '1',
          ),
          profile: DatecsProfile.asciiMx,
        ),
      ];
      for (final device in devices) {
        expect((await device.readStatus()).ready, true, reason: device.name);
        expect(device.capabilities, contains('nonFiscal'));
        if (e['COMPANION_SMOKE_PRINT'] == '1') {
          final result = await device.nonFiscal([
            'CHIMERA - UNIFIED API',
            'TEST NEFISCAL - FARA INCASARE',
          ]);
          expect(
            result.outcome,
            CommandOutcome.succeeded,
            reason: '${device.name}: ${result.message}',
          );
        }
      }
    },
    skip: Platform.environment['COMPANION_HARDWARE_TEST'] != '1',
  );
}
