import 'dart:io';
import 'package:crypto/crypto.dart';
import 'connection.dart';

LanEndpoint vivaEndpoint(String host, String port) => LanEndpoint(
  host: host.trim().isEmpty || host.trim().toLowerCase() == 'localhost'
      ? '127.0.0.1'
      : host.trim(),
  port: port.trim().isEmpty ? 9564 : int.parse(port.trim()),
);

class VivaConnectionCheck {
  const VivaConnectionCheck({
    required this.message,
    this.certificate,
    this.trusted = false,
  });
  final String message;
  final String? certificate;
  final bool trusted;
}

/// TLS handshake only: no sale, refund, mode change or HTTP request is sent.
/// An unknown certificate is captured but rejected until the user confirms it.
Future<VivaConnectionCheck> checkVivaConnection(
  LanEndpoint endpoint,
  String pin,
) async {
  if (pin.isNotEmpty && !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(pin)) {
    throw ArgumentError(
      'Amprenta certificatului trebuie să conțină 64 caractere hexazecimale.',
    );
  }
  String? observed;
  SecureSocket? socket;
  try {
    socket = await SecureSocket.connect(
      endpoint.host,
      endpoint.port,
      context: SecurityContext(withTrustedRoots: false),
      timeout: const Duration(seconds: 5),
      onBadCertificate: (certificate) {
        observed = sha256.convert(certificate.der).toString();
        return pin.isNotEmpty && observed == pin.toLowerCase();
      },
    );
    final certificate = socket.peerCertificate;
    if (certificate != null) {
      observed = sha256.convert(certificate.der).toString();
    }
    if (pin.isEmpty || observed != pin.toLowerCase()) {
      return VivaConnectionCheck(
        message:
            'Terminal HTTPS găsit. Confirmă certificatul înainte de utilizare.',
        certificate: observed,
      );
    }
    return VivaConnectionCheck(
      message:
          'Conexiune HTTPS verificată · ${endpoint.host}:${endpoint.port}. Nu s-a inițiat nicio plată.',
      trusted: true,
      certificate: observed,
    );
  } on HandshakeException {
    if (observed != null) {
      return VivaConnectionCheck(
        message: pin.isEmpty
            ? 'Terminal HTTPS găsit. Confirmă certificatul înainte de utilizare.'
            : 'Certificatul terminalului nu corespunde celui salvat. Conexiune refuzată.',
        certificate: pin.isEmpty ? observed : null,
      );
    }
    return const VivaConnectionCheck(
      message:
          'Negocierea HTTPS a eșuat. Verifică Peer to Peer și portul afișat în Viva Terminal.',
    );
  } on SocketException {
    return VivaConnectionCheck(
      message:
          'Viva inaccesibil la ${endpoint.host}:${endpoint.port}. Activează More → Integrations → Viva Peer to Peer. Localhost funcționează numai pe același dispozitiv.',
    );
  } finally {
    socket?.destroy();
  }
}
