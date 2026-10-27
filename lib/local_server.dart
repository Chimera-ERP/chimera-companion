import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'security/offline_session.dart';
import 'customer_display_stream.dart';
import 'console/console_service.dart';
import 'console/console_stream.dart';
import 'package:flutter/services.dart' show rootBundle;

typedef VerifyTicket = Future<Map<String, dynamic>> Function(String ticket);
typedef RunHardware =
    Future<Map<String, Object?>> Function(
      String operation,
      String id,
      Map<String, dynamic> payload,
    );
typedef RunAuthorizedHardware =
    Future<Map<String, Object?>> Function(
      String,
      String,
      Map<String, dynamic>,
      int,
    );

/// No device credentials or unauthenticated hardware endpoints on the LAN.
class CompanionServer {
  CompanionServer({
    required this.verify,
    required this.run,
    this.security,
    this.runAuthorized,
    this.onAuthorizationError,
    this.onFailure,
    this.runProductionPrint,
    this.runProductionLabel,
    this.console,
  });
  final RunAuthorizedHardware? runAuthorized;
  final ConsoleService? console;
  final Set<WebSocket> _consoleSockets = {};
  final Future<Map<String, Object?>> Function(Map<String, dynamic>, String)?
  runProductionLabel;
  final Future<Map<String, Object?>> Function(
    String,
    Map<String, dynamic>,
    String,
  )?
  runProductionPrint;
  final Future<void> Function(String)? onAuthorizationError;
  final Future<void> Function(String, String)? onFailure;
  final VerifyTicket verify;
  final RunHardware run;
  final OfflineSession? security;
  HttpServer? _server;
  bool _executing = false;
  int _active = 0;
  Set<String>? _allowedHosts;
  final Set<WebSocket> _displaySockets = {};
  int get port => _server!.port;
  bool get running => _server != null;
  Future<void> start({
    required SecurityContext securityContext,
    InternetAddress? address,
    int port = 8765,
    Set<String>? allowedHosts,
  }) async {
    _allowedHosts = allowedHosts;
    _server = await HttpServer.bindSecure(
      address ?? InternetAddress.anyIPv4,
      port,
      securityContext,
    );
    _server!.idleTimeout = const Duration(seconds: 10);
    _server!.listen((request) {
      unawaited(_handle(request));
    });
  }

  Future<void> close() async {
    for (final socket in _consoleSockets.toList()) {
      await socket.close(WebSocketStatus.goingAway);
    }
    for (final socket in _displaySockets.toList()) {
      await socket.close(WebSocketStatus.goingAway);
    }
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    final origin = request.headers.value('Origin');
    final url = origin == null ? null : Uri.tryParse(origin);
    if (url != null &&
        ['https', 'http'].contains(url.scheme) &&
        url.origin == origin) {
      response.headers.set('Access-Control-Allow-Origin', origin!);
      response.headers.set('Vary', 'Origin');
      response.headers.set(
        'Access-Control-Allow-Methods',
        'POST, GET, OPTIONS',
      );
      response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
      response.headers.set('Access-Control-Allow-Private-Network', 'true');
    }
    Future<void> reply(int status, Map<String, Object?> body) async {
      try {
        if (status >= 400) {
          await onFailure?.call(
            'http_rejected',
            'HTTP $status · ${body['error'] ?? 'Local request rejected'}',
          );
        } else if (['rejected', 'unknown'].contains(body['outcome'])) {
          await onFailure?.call(
            'command_${body['outcome']}',
            body['message'] as String? ?? 'Command not confirmed',
          );
        }
      } catch (_) {}
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
      await response.close();
    }

    if (_active >= 8) {
      await reply(429, {'error': 'Companion busy'});
      return;
    }
    _active++;
    try {
      final requestHost = request.headers.host?.toLowerCase();
      if (_allowedHosts != null && !_allowedHosts!.contains(requestHost)) {
        await reply(421, {'error': 'Unexpected Companion hostname'});
        return;
      }
      if (request.uri.query.isNotEmpty) {
        await reply(400, {'error': 'Query parameters not supported'});
        return;
      }
      if (request.method == 'OPTIONS' &&
          [
            '/v1/commands',
            '/v2/challenge',
            '/v1/production-print',
            '/v1/production-label',
          ].contains(request.uri.path)) {
        await reply(200, {});
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/health') {
        await reply(200, {'service': 'chimera-companion', 'version': 1});
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/v1/kds-console') {
        if (security == null ||
            console == null ||
            !console!.connected ||
            origin == null ||
            url == null ||
            !(url.scheme == 'https' ||
                (url.scheme == 'http' &&
                    ['localhost', '127.0.0.1', '::1'].contains(url.host))) ||
            !WebSocketTransformer.isUpgradeRequest(request)) {
          await reply(403, {'error': 'Consolă HTTPS autorizată necesară'});
          return;
        }
        if (_consoleSockets.isNotEmpty) {
          await reply(409, {'error': 'Consola este folosită de alt KDS'});
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        _consoleSockets.add(socket);
        try {
          await serveConsole(socket, origin, security!, console!);
        } finally {
          _consoleSockets.remove(socket);
        }
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/customer-display') {
        // Public template only: no cart data or keys, even on an unpaired LAN.
        response.headers.contentType = ContentType.html;
        response.write(
          await rootBundle.loadString('assets/customer-display/index.html'),
        );
        await response.close();
        return;
      }
      if (request.method == 'GET' &&
          request.uri.path == '/v2/customer-display') {
        if (security == null ||
            origin == null ||
            url?.scheme != 'https' ||
            url?.origin != origin ||
            !WebSocketTransformer.isUpgradeRequest(request)) {
          await reply(403, {
            'error': 'Secure paired display connection required',
          });
          return;
        }
        if (_displaySockets.length >= 2) {
          await reply(429, {'error': 'Display connections busy'});
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        _displaySockets.add(socket);
        try {
          await serveCustomerDisplayStream(socket, origin, security!, (
            id,
            payload,
            expires,
          ) async {
            if (runAuthorized == null) {
              throw StateError('Verified dispatch required');
            }
            return runAuthorized!('customerDisplay', id, payload, expires);
          });
        } finally {
          _displaySockets.remove(socket);
        }
        return;
      }
      if (request.method != 'POST' ||
          ![
            '/v1/commands',
            '/v2/challenge',
            '/v1/production-print',
            '/v1/production-label',
          ].contains(request.uri.path)) {
        await reply(404, {'error': 'Not found'});
        return;
      }
      if (origin == null ||
          url == null ||
          !['http', 'https'].contains(url.scheme) ||
          request.headers.contentType?.mimeType != 'application/json') {
        await reply(403, {'error': 'POS origin and JSON required'});
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        bytes.addAll(chunk);
        if (bytes.length > 32768) {
          await reply(413, {'error': 'Payload too large'});
          return;
        }
      }
      final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (request.uri.path == '/v1/production-label') {
        if (runProductionLabel == null || url.scheme != 'https') {
          await reply(403, {
            'error': 'Provisional label authorization unavailable',
          });
          return;
        }
        try {
          if (body.length != 4 ||
              body['lease'] is! String ||
              body['payload'] is! Map<String, dynamic> ||
              body['message'] is! String ||
              body['signature'] is! String) {
            throw const FormatException('Invalid label envelope');
          }
          await reply(200, await runProductionLabel!(body, origin));
        } on FormatException catch (error) {
          await reply(403, {
            'error': error.message.startsWith('Câmpul ')
                ? error.message
                : 'Provisional label scope or device proof rejected',
          });
        } on StateError {
          await reply(409, {
            'error': 'Label identity, report, reprint or lease limit conflict',
          });
        }
        return;
      }
      if (request.uri.path == '/v1/production-print') {
        if (runProductionPrint == null || url.scheme != 'https') {
          await reply(403, {
            'error': 'Production printing authorization unavailable',
          });
          return;
        }
        try {
          if (body.length != 2 ||
              body['ticket'] is! String ||
              body['payload'] is! Map<String, dynamic>) {
            throw const FormatException('Invalid print envelope');
          }
          await reply(
            200,
            await runProductionPrint!(body['ticket'], body['payload'], origin),
          );
        } on FormatException catch (error) {
          await reply(403, {
            'error': error.message.startsWith('Câmpul ')
                ? error.message
                : 'Production print authorization or payload rejected',
          });
        } on StateError {
          await reply(409, {
            'error': 'Print identity conflict or queue unavailable',
          });
        }
        return;
      }
      final session = security;
      if (session != null) {
        if (request.uri.path == '/v2/challenge') {
          try {
            await reply(200, await session.challenge(body['lease'] as String));
          } on FormatException {
            await reply(403, {'error': 'Authorization rejected'});
          } on TypeError {
            await reply(400, {'error': 'Invalid authorization request'});
          }
          return;
        }
        if (body['lease'] is! String) {
          await reply(401, {
            'error': 'Signing authorization required; legacy tickets disabled',
          });
          return;
        }
        Map<String, dynamic> proof;
        try {
          proof = await session.authorize(body, origin);
        } on FormatException catch (error) {
          try {
            await onAuthorizationError?.call(error.message);
          } catch (_) {}
          await reply(403, {'error': 'Authorization rejected'});
          return;
        } on TypeError {
          try {
            await onAuthorizationError?.call(
              'Invalid authorization request shape',
            );
          } catch (_) {}
          await reply(400, {'error': 'Invalid authorization request'});
          return;
        }
        try {
          final commandPayload = Map<String, dynamic>.from(proof['payload']);
          if (proof['operation'] == 'customerDisplay') {
            commandPayload['posId'] = proof['pos'];
          }
          // A browser cannot override the ERP-signed checkout policy.
          if ([
            'fiscalReceipt',
            'saleAuthorize',
            'saleExternalPaymentConfirm',
            'fiscalPolicy',
          ].contains(proof['operation'])) {
            commandPayload['checkoutPolicy'] = proof['checkoutPolicy'];
          }
          if (proof['operation'] == 'saleAuthorize') {
            commandPayload['authorizationExpires'] =
                proof['authorizationExpires'];
          }
          if ([
                'operatorLogin',
                'operatorLogout',
              ].contains(proof['operation']) &&
              commandPayload['expectedOperatorId'] != null &&
              commandPayload['expectedOperatorId'] != proof['operatorId']) {
            await reply(403, {'error': 'Operator changed before command'});
            return;
          }
          if ([
            'operatorLogin',
            'operatorLogout',
            'drawerCountStart',
            'drawerCountEnd',
            'fiscalReceipt',
            'cashDeposit',
            'cashWithdraw',
            'saleAuthorize',
            'salePaymentStart',
            'salePaymentReject',
            'saleAbandon',
            'saleExternalPaymentConfirm',
            'fiscalPolicy',
            'payment',
          ].contains(proof['operation'])) {
            commandPayload['operatorName'] = proof['operatorName'];
            commandPayload['posId'] = proof['pos'];
            commandPayload['operatorId'] = proof['operatorId'];
            commandPayload['canResetOperatorReport'] =
                proof['canResetOperatorReport'];
          }
          final result = runAuthorized == null
              ? await run(
                  proof['operation'],
                  proof['commandId'],
                  commandPayload,
                )
              : await runAuthorized!(
                  proof['operation'],
                  proof['commandId'],
                  commandPayload,
                  proof['authorizationExpires'] as int,
                );
          await reply(
            200,
            await session.result({
              ...result,
              'commandId': proof['commandId'],
              'operation': proof['operation'],
              'operatorId': proof['operatorId'],
              'posId': proof['pos'],
              if (proof['operatorSession'] != null)
                'operatorSession': proof['operatorSession'],
            }, proof['payloadHash']),
          );
        } on StateError {
          await reply(409, {
            'error': 'Command identity conflict or queue unavailable',
          });
        } on FormatException {
          await reply(403, {
            'error':
                'Autorizarea sau datele comenzii nu corespund. Verifică jurnalul înainte de o încercare nouă.',
          });
        }
        return;
      }
      if (request.uri.path == '/v2/challenge') {
        await reply(503, {'error': 'Offline authorization not configured'});
        return;
      }
      final ticket = body['ticket'];
      final payloadJson = body['payloadJson'];
      if (ticket is! String || ticket.length > 4096 || payloadJson is! String) {
        await reply(400, {'error': 'Invalid command envelope'});
        return;
      }
      final claims = await verify(ticket);
      if (claims['origin'] != origin ||
          claims['hash'] !=
              sha256.convert(utf8.encode(payloadJson)).toString() ||
          claims['exp'] is! num ||
          (claims['exp'] as num) <= DateTime.now().millisecondsSinceEpoch ||
          ![
            'status',
            'nonFiscal',
            'paymentTest',
            'payment',
            'fiscalReceipt',
            'xReport',
            'zReport',
            'history',
          ].contains(claims['operation']) ||
          claims['commandId'] is! String) {
        await reply(403, {
          'error': 'Authorization does not match this request',
        });
        return;
      }
      final readOnly = ['status', 'history'].contains(claims['operation']);
      if (_executing && !readOnly) {
        await reply(409, {'error': 'Another hardware command is in progress'});
        return;
      }
      final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
      if (!readOnly) _executing = true;
      try {
        final result = await run(
          claims['operation'] as String,
          claims['commandId'] as String,
          payload,
        );
        await reply(200, {...result, 'commandId': claims['commandId']});
      } finally {
        if (!readOnly) _executing = false;
      }
    } on FormatException {
      await reply(400, {'error': 'Invalid JSON'});
    } on ArgumentError {
      await reply(400, {'error': 'Invalid hardware payload'});
    } catch (_) {
      try {
        await reply(503, {
          'error': 'Command not confirmed. Check Companion before retrying.',
        });
      } catch (_) {}
    } finally {
      _active--;
    }
  }
}
