import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'security/device_identity.dart';
import 'tls_provisioning.dart';
import 'device_credentials.dart';

class ConnectivityClient {
  ConnectivityClient({
    required this.provisioning,
    this.identity,
    this.request,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final TlsProvisioning provisioning;
  final DeviceIdentity? identity;
  final DateTime Function() clock;
  final Future<Map<String, dynamic>> Function(
    Uri,
    Map<String, dynamic>,
    String?,
  )?
  request;
  static const _storage = FlutterSecureStorage();
  Future<Map<String, dynamic>> _post(
    Uri uri,
    Map<String, dynamic> payload, {
    String? token,
  }) async {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const FormatException('HTTPS necesar.');
    }
    if (request != null) return request!(uri, payload, token);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .postUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(
        const Duration(minutes: 3),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 262144) {
          throw const FormatException('Răspuns prea mare.');
        }
      }
      if ([502, 503, 504].contains(response.statusCode)) {
        throw const SocketException('Serviciu temporar indisponibil');
      }
      if (response.statusCode != 200) {
        String? detail;
        try {
          final data = jsonDecode(utf8.decode(bytes));
          if (data is Map && data['error'] is String) {
            detail = data['error'] as String;
          }
        } catch (_) {
          /* Non-JSON proxy responses use the HTTP status below. */
        }
        if (response.statusCode == 409) {
          final data = jsonDecode(utf8.decode(bytes));
          if (data is Map && data['code'] == 'TRANSPORT_NOT_CONFIGURED') {
            throw const HttpException(
              'Conexiunea HTTPS nu este configurată pentru organizație. În Chimera → Integrări → Domeniu și conectivitate, administratorul trebuie să activeze integrarea.',
            );
          }
        }
        throw HttpException(
          detail ??
              'Configurarea nu a fost acceptată de ${uri.host}${uri.path} (HTTP ${response.statusCode}).',
        );
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  static String privateIp(String lanIp) {
    final ip = InternetAddress.tryParse(lanIp.trim());
    if (ip == null || ip.type != InternetAddressType.IPv4) {
      throw const FormatException('Introdu IP-ul LAN IPv4 al Companion-ului.');
    }
    final octets = ip.rawAddress;
    if (!(octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168))) {
      throw const FormatException(
        'IP-ul trebuie să fie privat, din rețeaua locală.',
      );
    }
    return ip.address;
  }

  Map<String, dynamic> _validateAuthorization(
    Map<String, dynamic> value,
    Map<String, dynamic> pairing,
  ) {
    if (!['managed', 'self_hosted'].contains(value['mode'])) {
      throw StateError('Serviciul DNS/certificate nu este activat.');
    }
    final service = Uri.parse(value['service_url'] as String);
    if (service.scheme != 'https' ||
        service.userInfo.isNotEmpty ||
        service.hasQuery ||
        service.hasFragment ||
        !['', '/', '/connectivity', '/connectivity/'].contains(service.path)) {
      throw const FormatException('Adresă serviciu invalidă.');
    }
    final parts = (value['ticket'] as String).split('.');
    if (parts.length != 3) throw const FormatException('Autorizare invalidă.');
    final claims =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, dynamic>;
    final now = clock().millisecondsSinceEpoch ~/ 1000;
    if (claims['sub'] != pairing['device_id'] ||
        claims['kind'] != 'transport' ||
        claims['aud'] != 'chimera-connectivity' ||
        claims['exp'] is! int ||
        claims['iat'] is! int ||
        claims['exp'] <= now ||
        claims['iat'] > now + 5 ||
        claims['exp'] - claims['iat'] > 604800 ||
        claims['exp'] <= claims['iat']) {
      throw const FormatException(
        'Autorizarea serviciului a expirat sau nu aparține dispozitivului.',
      );
    }
    final host = TlsProvisioning.hostname(value['hostname'] as String);
    final expected =
        'c-${sha256.convert(utf8.encode(pairing['device_id'] as String)).toString().substring(0, 24)}.companions.${claims['zone']}';
    if (host != expected) {
      throw const FormatException(
        'Hostname diferit de identitatea dispozitivului.',
      );
    }
    return value;
  }

  Future<Map<String, dynamic>> _authorization(
    Map<String, dynamic> pairing,
    DeviceIdentity signer,
  ) async {
    final saved = await _storage.read(key: 'connectivity_authorization_v1');
    Map<String, dynamic>? cached;
    if (saved != null) {
      final entry = jsonDecode(saved) as Map<String, dynamic>;
      if (entry['device_id'] == pairing['device_id'] &&
          entry['erp_url'] == pairing['erp_url']) {
        cached = entry;
      }
    }
    final erp = Uri.parse(pairing['erp_url'] as String);
    try {
      if (request == null) pairing = await currentDevicePairing();
      await _post(
        erp.resolve('/api/devices/companion/offline/identity'),
        {'public_jwk': await signer.publicKey()},
        token: pairing['token'] as String,
      );
      final current = await _post(
        erp.resolve('/api/devices/companion/offline/transport-ticket'),
        {},
        token: pairing['token'] as String,
      );
      _validateAuthorization(current, pairing);
      await _storage.write(
        key: 'connectivity_authorization_v1',
        value: jsonEncode({
          'device_id': pairing['device_id'],
          'erp_url': pairing['erp_url'],
          'authorization': current,
        }),
      );
      return current;
    } on SocketException {
      if (cached == null) rethrow;
    } on TimeoutException {
      if (cached == null) rethrow;
    } on HttpException {
      // An explicit denial must not fall back to a cached authorization.
      await _storage.delete(key: 'connectivity_authorization_v1');
      rethrow;
    } on StateError {
      await _storage.delete(key: 'connectivity_authorization_v1');
      rethrow;
    } on FormatException {
      await _storage.delete(key: 'connectivity_authorization_v1');
      rethrow;
    }
    return _validateAuthorization(
      cached['authorization'] as Map<String, dynamic>,
      pairing,
    );
  }

  Future<DateTime> configure(
    String lanIp, {
    bool onlyIfDue = false,
    String? interfaceName,
  }) async {
    final ip = privateIp(lanIp);
    final raw = await _storage.read(key: 'erp_pairing_v1');
    if (raw == null) {
      throw StateError('Asociază mai întâi Companion-ul cu ERP.');
    }
    final pairing = jsonDecode(raw) as Map<String, dynamic>;
    final signer = identity ?? DeviceIdentity();
    final authorization = await _authorization(pairing, signer);
    if (!['managed', 'self_hosted'].contains(authorization['mode'])) {
      throw StateError(
        'Activează Domeniu și conectivitate în Integrări, în Chimera.',
      );
    }
    final service = Uri.parse(authorization['service_url'] as String);
    if (service.scheme != 'https' ||
        service.userInfo.isNotEmpty ||
        service.hasQuery ||
        service.hasFragment ||
        !['', '/', '/connectivity', '/connectivity/'].contains(service.path)) {
      throw const FormatException('Adresă serviciu invalidă.');
    }
    final host = TlsProvisioning.hostname(authorization['hostname'] as String);
    Future<Map<String, dynamic>> signed(
      String operation,
      Map<String, dynamic> data,
    ) async {
      final nonce = List<int>.generate(24, (_) => Random.secure().nextInt(256));
      final message = jsonEncode({
        'operation': operation,
        'timestamp': clock().millisecondsSinceEpoch,
        'nonce': base64UrlEncode(nonce).replaceAll('=', ''),
        ...data,
      });
      final base = service.path.replaceFirst(RegExp(r'/$'), '');
      return _post(service.replace(path: '$base/v1/$operation'), {
        'ticket': authorization['ticket'],
        'message': message,
        'signature': await signer.sign(message),
      });
    }

    final address = await signed('address', {'ip': ip});
    if (address['hostname'] != host) {
      throw const FormatException('Hostname DNS diferit de autorizare.');
    }
    await _storage.write(
      key: 'connectivity_settings_v1',
      value: jsonEncode({
        'device_id': pairing['device_id'],
        'ip': ip,
        'interface': interfaceName,
      }),
    );
    final bundle = File('${provisioning.directory.path}/bundle.json');
    if (onlyIfDue && await bundle.exists()) {
      final current =
          jsonDecode(await bundle.readAsString()) as Map<String, dynamic>;
      final expires = DateTime.tryParse(current['expiresAt'] as String? ?? '');
      if (current['origin'] == 'https://$host:8765' &&
          expires != null &&
          expires.isAfter(clock().add(const Duration(days: 30)))) {
        return expires;
      }
    }
    final csr = await provisioning.createCsr(host);
    final issued = await signed('certificate', {'csr': csr});
    if (issued['hostname'] != host || issued['certificate'] is! String) {
      throw const FormatException('Certificat diferit de autorizare.');
    }
    return provisioning.install(host, issued['certificate'] as String);
  }

  /// Returns null for manual/proxy setups. Ambiguous interfaces need explicit
  /// selection rather than publishing a VPN or a different network silently.
  Future<DateTime?> maintain() async {
    final raw = await _storage.read(key: 'connectivity_settings_v1');
    if (raw == null) return null;
    final saved = jsonDecode(raw) as Map<String, dynamic>;
    final pairingRaw = await _storage.read(key: 'erp_pairing_v1');
    if (pairingRaw == null) return null;
    final pairing = jsonDecode(pairingRaw) as Map<String, dynamic>;
    if (pairing['device_id'] != saved['device_id']) {
      throw StateError(
        'Asocierea Companion s-a schimbat. Reconfigurează HTTPS.',
      );
    }
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final candidates = <({String name, String ip})>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        try {
          privateIp(address.address);
          candidates.add((name: interface.name, ip: address.address));
        } on FormatException {
          continue;
        }
      }
    }
    final selected = selectLanAddress(
      candidates,
      saved['ip'] as String,
      saved['interface'] as String?,
    );
    return configure(
      selected.ip,
      onlyIfDue: true,
      interfaceName: selected.name,
    );
  }
}

Future<({String name, String ip})> detectLanAddress() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  final candidates = <({String name, String ip})>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      try {
        candidates.add((
          name: interface.name,
          ip: ConnectivityClient.privateIp(address.address),
        ));
      } on FormatException {
        continue;
      }
    }
  }
  return initialLanAddress(candidates);
}

({String name, String ip}) initialLanAddress(
  List<({String name, String ip})> candidates,
) {
  final physical = candidates
      .where(
        (item) => RegExp(
          r'^(wlan|wifi|en\d|eth\d)',
          caseSensitive: false,
        ).hasMatch(item.name),
      )
      .toList();
  final wifi = physical
      .where(
        (item) =>
            RegExp(r'^(wlan|wifi)', caseSensitive: false).hasMatch(item.name),
      )
      .toList();
  if (wifi.length == 1) return wifi.single;
  if (physical.length == 1) return physical.single;
  if (physical.isEmpty &&
      candidates.length == 1 &&
      !RegExp(
        r'^(tun|tap|utun|lo)',
        caseSensitive: false,
      ).hasMatch(candidates.single.name)) {
    return candidates.single;
  }
  throw StateError(
    'Nu pot identifica o singură adresă LAN. Conectează telefonul la Wi-Fi sau introdu adresa în setările avansate.',
  );
}

({String name, String ip}) selectLanAddress(
  List<({String name, String ip})> candidates,
  String previous,
  String? interfaceName,
) {
  final matching = candidates
      .where(
        (item) => interfaceName != null
            ? item.name == interfaceName
            : item.ip == previous,
      )
      .toList();
  if (matching.length == 1) return matching.single;
  if (interfaceName == null && candidates.length == 1) return candidates.single;
  throw StateError(
    'Rețeaua LAN este indisponibilă sau ambiguă. Selectează IP-ul în configurarea HTTPS.',
  );
}
