import 'dart:convert';

import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/tremol_adapter.dart';
import 'package:chimera_companion/hardware/tremol_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'adapters_test.dart' show TremolPeer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chimera/fiscal-serial');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const serial = 'TEST0000001';
  final id = sha256
      .convert(utf8.encode('fiscal/tremolFp21/$serial'))
      .toString();
  final usb = FiscalSerialEndpoint(
    model: FiscalModel.tremolFp21,
    transport: 'usb',
    deviceId: id,
    baudRate: 57600,
  );
  final radio = Fp21Bluetooth(usb);
  late String connectedSerial;
  late String firmware;
  late String inventory;
  late String state;
  late String radioReplyPrefix;
  late List<String> requests;
  late TremolPeer peer;
  late bool loseAcknowledgement;
  late bool loseVerification;
  late bool disconnectOnRead;
  late bool acceptEnable;
  late Uint8List? pending;
  late int opened;
  late int closed;

  setUp(() {
    connectedSerial = serial;
    firmware = 'R;D;S;1;0;1;1';
    inventory = 'R;D;D;1;0;1;1';
    state = '0';
    radioReplyPrefix = 'R;B;S';
    requests = [];
    peer = TremolPeer();
    loseAcknowledgement = false;
    loseVerification = false;
    disconnectOnRead = false;
    acceptEnable = true;
    pending = null;
    opened = 0;
    closed = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'open':
          expect(call.arguments, {
            'id': id,
            'transport': 'usb',
            'baudRate': 57600,
          });
          return ++opened;
        case 'close':
          expect(call.arguments['session'], opened);
          closed++;
          return null;
        case 'read':
          expect(call.arguments['session'], opened);
          if (disconnectOnRead) {
            disconnectOnRead = false;
            pending = null;
            throw PlatformException(code: 'DISCONNECT');
          }
          final result = pending!;
          pending = null;
          return result;
        case 'write':
          expect(call.arguments['session'], opened);
          expect(pending, isNull);
          final bytes = call.arguments['bytes'] as Uint8List;
          if (bytes.first == 9 || bytes[3] == 0x20) {
            pending = Uint8List.fromList(
              await peer.exchange(bytes, TremolProtocol.frameLength),
            );
            return null;
          }
          final sequence = bytes[2];
          final command = bytes[3];
          if (command == 0x60) {
            requests.add('serial');
            pending = Uint8List.fromList(
              TremolProtocol.encode(
                sequence,
                command,
                ascii.encode(connectedSerial),
              ),
            );
            return null;
          }
          expect(command, 0x4e);
          final key = ascii.decode(bytes.sublist(4, bytes.length - 3));
          requests.add(key);
          if (key == 'P;B;S;1') {
            if (acceptEnable) state = '1';
            pending = Uint8List.fromList(
              await peer.exchange(bytes, TremolProtocol.frameLength),
            );
            disconnectOnRead = loseAcknowledgement;
            return null;
          }
          final String response = switch (key) {
            'R;D;S' => firmware,
            'R;D;D' => inventory,
            'R;B;S' => '$radioReplyPrefix;$state',
            _ => fail('Unexpected FP21 command $key'),
          };
          if (key == 'R;B;S' &&
              requests.contains('P;B;S;1') &&
              loseVerification) {
            loseVerification = false;
            disconnectOnRead = true;
          }
          pending = Uint8List.fromList(
            TremolProtocol.encode(sequence, command, ascii.encode(response)),
          );
          return null;
        default:
          fail('Unexpected serial method ${call.method}');
      }
    });
  });
  tearDown(() {
    expect(closed, opened);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'captured FP21 inventory echo still requires independent radio status',
    () async {
      inventory = 'R;D;S;1;0;1;1';
      expect(await radio.readState(), Fp21BluetoothState.disabled);
      expect(requests, ['serial', 'R;D;S', 'R;D;D', 'R;B;S']);
      radioReplyPrefix = 'R;B;P';
      await expectLater(radio.enable(), throwsFormatException);
      expect(requests, isNot(contains('P;B;S;1')));
    },
  );

  test(
    'unsupported firmware or absent module stops before configuration',
    () async {
      firmware = 'R;D;S;1;0;1;0';
      expect(await radio.enable(), Fp21BluetoothState.unsupportedFirmware);
      expect(requests, ['serial', 'R;D;S']);
      firmware = 'R;D;S;1;0;1;1';
      inventory = 'R;D;D;1;0;1;0';
      requests.clear();
      expect(await radio.enable(), Fp21BluetoothState.moduleAbsent);
      expect(requests, ['serial', 'R;D;S', 'R;D;D']);
    },
  );

  test(
    'ignores unsupported shape and negative ambiguous inventory echo',
    () async {
      for (final invalid in [
        'R;D;D;0;2;0;1',
        'R;D;X;0;0;0;1',
        'R;D;S;1;0;1;0',
      ]) {
        inventory = invalid;
        await expectLater(radio.enable(), throwsFormatException);
      }
      expect(requests, isNot(contains('P;B;S;1')));
    },
  );

  test(
    'enable verifies its outcome and never reprograms an enabled radio',
    () async {
      expect(await radio.enable(), Fp21BluetoothState.enabled);
      expect(requests, [
        'serial',
        'R;D;S',
        'R;D;D',
        'R;B;S',
        'P;B;S;1',
        'R;B;S',
      ]);
      requests.clear();
      expect(await radio.enable(), Fp21BluetoothState.enabled);
      expect(requests, ['serial', 'R;D;S', 'R;D;D', 'R;B;S']);
    },
  );

  test('acknowledged set still reports disabled if readback is zero', () async {
    acceptEnable = false;
    expect(await radio.enable(), Fp21BluetoothState.disabled);
    expect(requests.where((key) => key == 'P;B;S;1'), hasLength(1));
  });

  for (final lost in ['acknowledgement', 'verification']) {
    test(
      'a lost $lost produces an uncertain outcome, then reading reconciles it',
      () async {
        loseAcknowledgement = lost == 'acknowledgement';
        loseVerification = lost == 'verification';
        expect(await radio.enable(), Fp21BluetoothState.unconfirmed);
        expect(await radio.readState(), Fp21BluetoothState.enabled);
        expect(await radio.enable(), Fp21BluetoothState.enabled);
        expect(requests.where((key) => key == 'P;B;S;1'), hasLength(1));
      },
    );
  }

  test(
    'refuses to configure a different USB register or an open document',
    () async {
      connectedSerial = 'TEST0000002';
      await expectLater(radio.enable(), throwsStateError);
      expect(requests, ['serial']);
      connectedSerial = serial;
      for (final openFlag in [1, 2]) {
        peer.statusBytes[2] = openFlag;
        await expectLater(radio.enable(), throwsStateError);
      }
      expect(requests, isNot(contains('P;B;S;1')));
    },
  );

  test('rejects other models and wireless programming endpoints', () {
    final other = FiscalSerialEndpoint(
      model: FiscalModel.tremolM20,
      transport: 'usb',
      deviceId: id,
    );
    final wireless = FiscalSerialEndpoint(
      model: FiscalModel.tremolFp21,
      transport: 'bluetooth',
      deviceId: 'AA:BB:CC:DD:EE:FF',
    );
    expect(() => Fp21Bluetooth(other), throwsArgumentError);
    expect(() => Fp21Bluetooth(wireless), throwsArgumentError);
    expect(opened, isZero);
  });
}
