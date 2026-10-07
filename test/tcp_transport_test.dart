import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/connection.dart';
import 'package:chimera_companion/hardware/tcp_transport.dart';
import 'package:chimera_companion/hardware/tremol_protocol.dart';

void main() {
  test(
    'real socket transport reassembles fragmented frames without retransmitting',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final writes = <List<int>>[];
      final response = TremolProtocol.encode(0x20, 0x20, [
        0,
        0,
        0,
        0x30,
        0,
        0,
        0,
      ]);
      final subscription = server.listen((socket) {
        sockets.add(socket);
        socket.listen((bytes) async {
          writes.add(bytes);
          socket.add(response.sublist(0, 4));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
          socket.add(response.sublist(4));
        });
      });
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await subscription.cancel();
        await server.close();
      });
      final session = await TcpByteSession.connect(
        LanEndpoint(host: '127.0.0.1', port: server.port),
      );
      addTearDown(session.close);
      expect(
        await session.exchange(
          TremolProtocol.encode(0x20, 0x20, []),
          TremolProtocol.frameLength,
        ),
        response,
      );
      expect(writes.length, 1);
    },
  );
}
