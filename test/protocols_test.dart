import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/datecs_gateway_protocol.dart';
import 'package:chimera_companion/hardware/tremol_protocol.dart';
import 'package:chimera_companion/hardware/money.dart';
import 'package:chimera_companion/hardware/connection.dart';

String hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
void main() {
  test('Datecs exact parity with gateway cc0f01f non-fiscal frames', () {
    expect(
      hex(DatecsGatewayProtocol.encode(38, '')),
      '013030323a5a303032360530313f3303',
    );
    expect(
      hex(DatecsGatewayProtocol.encode(42, 'HELLO WORLD\t\t\t\t\t\t')),
      '013030333b5a3030323a48454c4c4f20574f524c44090909090909053035343b03',
    );
    expect(
      hex(DatecsGatewayProtocol.encode(39, '')),
      '013030323a5a303032370530313f3403',
    );
  });
  test('Datecs preserves empty fields and validates checksums', () {
    final text = ascii.encode('0\t\t12.00\t');
    final body = [
      ...DatecsGatewayProtocol.nibbles(text.length + 5 + 32),
      ...text,
      5,
    ];
    final frame = [
      1,
      ...body,
      ...DatecsGatewayProtocol.nibbles(body.fold<int>(0, (a, b) => a + b)),
      3,
    ];
    expect(DatecsGatewayProtocol.decode(frame), ['0', '', '12.00']);
    frame[6] ^= 1;
    expect(() => DatecsGatewayProtocol.decode(frame), throwsFormatException);
  });
  test('Tremol RO framing, matching response and checksum', () {
    expect(TremolProtocol.encode(0x20, 0x20, []), [
      2,
      0x23,
      0x20,
      0x20,
      0x32,
      0x33,
      10,
    ]);
    final bytes = TremolProtocol.encode(0x21, 0x20, [0, 0, 0, 0x30, 0, 0, 0]);
    expect(
      TremolProtocol.decode(bytes, sequence: 0x21, command: 0x20).data.length,
      7,
    );
    expect(
      () => TremolProtocol.decode(bytes, sequence: 0x22, command: 0x20),
      throwsFormatException,
    );
    bytes[4] ^= 1;
    expect(
      () => TremolProtocol.decode(bytes, sequence: 0x21, command: 0x20),
      throwsFormatException,
    );
  });
  test('Tremol ACK errors are not successful receipts', () {
    final body = [0x20, 0x31, 0x30];
    final sum = body.fold<int>(0, (a, b) => a ^ b);
    final ack = [6, ...body, 0x30 + (sum >> 4), 0x30 + (sum & 15), 10];
    expect(
      TremolProtocol.decode(ack, sequence: 0x20, command: 0x30).error,
      '10',
    );
    expect(() => TremolProtocol.frameLength([0x50]), throwsFormatException);
  });
  test('money remains exact in minor units', () {
    expect(minorToDecimal(2000), '20.00');
    expect(lineTotalMinor(2000, '1'), 2000);
    expect(lineTotalMinor(1700, '0.125'), 213);
    expect(decimalToMinor('20.00'), 2000);
    expect(() => decimalToMinor('20.001'), throwsFormatException);
    expect(() => lineTotalMinor(100, '0'), throwsArgumentError);
  });
  test('hardware addresses reject external hosts and invalid ports', () {
    expect(LanEndpoint(host: '192.168.1.20', port: 9100).port, 9100);
    expect(() => LanEndpoint(host: '8.8.8.8', port: 9100), throwsArgumentError);
    expect(
      () => LanEndpoint(host: 'localhost', port: 9100),
      throwsArgumentError,
    );
    expect(
      () => LanEndpoint(host: '192.168.1.20', port: 0),
      throwsArgumentError,
    );
  });
}
