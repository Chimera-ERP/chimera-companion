import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'security/offline_session.dart';

typedef DisplayDispatch =
    Future<Map<String, Object?>> Function(String, Map<String, dynamic>, int);

/// Persistent TLS transport, not a bearer-session bypass. Every frame still
/// consumes a fresh signed challenge and the normal pairing authorization.
Future<void> serveCustomerDisplayStream(
  WebSocket socket,
  String origin,
  OfflineSession security,
  DisplayDispatch dispatch,
) async {
  socket.pingInterval = const Duration(seconds: 10);
  String? lease, expectedNonce;
  var deadline = Timer(
    const Duration(seconds: 5),
    () => socket.close(WebSocketStatus.policyViolation),
  );
  var window = DateTime.now(), count = 0;
  try {
    await for (final frame in socket) {
      if (frame is! String || utf8.encode(frame).length > 32768) {
        await socket.close(WebSocketStatus.messageTooBig);
        break;
      }
      final now = DateTime.now();
      if (now.difference(window).inSeconds >= 1) {
        window = now;
        count = 0;
      }
      if (++count > 20) {
        await socket.close(WebSocketStatus.policyViolation);
        break;
      }
      final body = jsonDecode(frame) as Map<String, dynamic>;
      if (lease == null) {
        if (body['type'] != 'hello' || body['lease'] is! String) {
          throw const FormatException('Signed pairing required');
        }
        lease = body['lease'] as String;
        final challenge = await security.challenge(lease);
        expectedNonce =
            jsonDecode(challenge['message'] as String)['challenge'] as String;
        socket.add(jsonEncode({'type': 'ready', 'challenge': challenge}));
        // An unauthenticated holder of a copied lease cannot hold a slot forever.
        deadline.cancel();
        deadline = Timer(
          const Duration(seconds: 5),
          () => socket.close(WebSocketStatus.policyViolation),
        );
        continue;
      }
      if (body['type'] != 'snapshot' || body['lease'] != lease) {
        throw const FormatException('Invalid stream frame');
      }
      final message =
          jsonDecode(body['message'] as String) as Map<String, dynamic>;
      if (message['operation'] != 'customerDisplay' ||
          message['challenge'] != expectedNonce) {
        throw const FormatException('Display-only channel');
      }
      final proof = await security.authorize(body, origin);
      final result = await dispatch(proof['commandId'] as String, {
        ...Map<String, dynamic>.from(proof['payload']),
        'posId': proof['pos'],
      }, proof['authorizationExpires'] as int);
      final signed = await security.result({
        ...result,
        'commandId': proof['commandId'],
        'operation': 'customerDisplay',
        'posId': proof['pos'],
      }, proof['payloadHash'] as String);
      final challenge = await security.challenge(lease);
      expectedNonce =
          jsonDecode(challenge['message'] as String)['challenge'] as String;
      socket.add(
        jsonEncode({'type': 'ack', 'result': signed, 'challenge': challenge}),
      );
      deadline.cancel();
      deadline = Timer(
        const Duration(seconds: 30),
        () => socket.close(WebSocketStatus.goingAway),
      );
    }
  } catch (_) {
    // No detailed auth errors, data, keys or native exception text on the LAN.
    await socket.close(
      WebSocketStatus.policyViolation,
      'Display stream rejected',
    );
  } finally {
    deadline.cancel();
  }
}
