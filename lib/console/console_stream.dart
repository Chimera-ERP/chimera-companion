import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../security/offline_session.dart';
import 'console_contract.dart';
import 'console_service.dart';

Future<void> serveConsole(
  WebSocket socket,
  String origin,
  OfflineSession security,
  ConsoleService console,
) async {
  var timer = Timer(
    const Duration(seconds: 5),
    () => socket.close(WebSocketStatus.policyViolation),
  );
  StreamSubscription<Map<String, Object>>? events;
  Map<String, dynamic>? claims;
  String? ticket, challenge;
  var authenticated = false, owns = false;
  var last = DateTime.fromMillisecondsSinceEpoch(0);
  try {
    await for (final raw in socket) {
      if (raw is! String || raw.length > 20000) {
        throw const FormatException('Invalid console message');
      }
      final body = jsonDecode(raw) as Map<String, dynamic>;
      if (claims == null) {
        ticket = body['ticket'] as String;
        claims = security.verifyConsole(ticket, origin);
        challenge = jsonEncode({
          'kind': 'kds-console',
          'nonce': base64Url.encode(
            List.generate(32, (_) => Random.secure().nextInt(256)),
          ),
          'companion': security.companion,
          'station': claims['pos'],
          'origin': origin,
          'ticketHash': sha256.convert(utf8.encode(ticket)).toString(),
        });
        socket.add(
          jsonEncode({
            'type': 'challenge',
            'message': challenge,
            'signature': await security.identity.sign(challenge),
          }),
        );
      } else if (!authenticated) {
        if (body['type'] != 'proof' ||
            body['message'] != challenge ||
            !security.verifyConsoleProof(
              claims,
              challenge!,
              body['signature'] as String,
            )) {
          throw const FormatException('Invalid console proof');
        }
        security.verifyConsole(ticket!, origin);
        console.acquire();
        owns = true;
        authenticated = true;
        timer.cancel();
        timer = Timer(
          DateTime.fromMillisecondsSinceEpoch(
            (claims['exp'] as int) * 1000,
          ).difference(DateTime.now()),
          () => socket.close(WebSocketStatus.policyViolation),
        );
        events = console.events.listen(
          (event) => socket.add(jsonEncode(event)),
        );
        socket.add(jsonEncode({'type': 'ready'}));
      } else {
        security.verifyConsole(ticket!, origin);
        if (body['type'] == 'renew') {
          final next = security.verifyConsole(body['ticket'] as String, origin);
          if (next['pos'] != claims['pos'] ||
              next['sub'] != claims['sub'] ||
              !['kty', 'crv', 'x', 'y'].every(
                (k) => next['cnf']['jwk'][k] == claims!['cnf']['jwk'][k],
              ) ||
              next['exp'] <= claims['exp']) {
            throw const FormatException('Console renewal identity changed');
          }
          ticket = body['ticket'] as String;
          claims = next;
          timer.cancel();
          timer = Timer(
            DateTime.fromMillisecondsSinceEpoch(
              (next['exp'] as int) * 1000,
            ).difference(DateTime.now()),
            () => socket.close(WebSocketStatus.policyViolation),
          );
          socket.add(jsonEncode({'type': 'renewed'}));
          continue;
        }
        final now = DateTime.now();
        if (now.difference(last).inMilliseconds < 40) {
          throw const FormatException('Console rate limit');
        }
        last = now;
        if (body['type'] != 'view') {
          throw const FormatException('Unknown console message');
        }
        final frame = ConsoleFrame.parse(body);
        await console.show(frame);
        socket.add(jsonEncode({'type': 'shown', 'revision': frame.revision}));
      }
    }
  } catch (_) {
    await socket.close(
      WebSocketStatus.policyViolation,
      'Consolă indisponibilă sau autorizare expirată',
    );
  } finally {
    timer.cancel();
    await events?.cancel();
    if (owns) await console.release();
    await socket.close();
  }
}
