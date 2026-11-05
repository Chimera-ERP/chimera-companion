import 'dart:convert';

const defaultEnrollmentOrigin = 'https://auth.chimeraerp.ro';

class EnrollmentRejected extends FormatException {
  const EnrollmentRejected(this.status, String message) : super(message);
  final int status;
}

// Public auth service route, also exposed unchanged by the development tunnel.
Uri enrollmentEndpoint(Uri erp) => erp.resolve('/auth/enroll-device');

Uri erpAddress(String input) {
  final value = input.trim();
  final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Introdu adresa ERP, de exemplu chimera.firma.ro.',
    );
  }
  return Uri.parse(uri.origin);
}

bool hasSavedEnrollment(String? saved) {
  if (saved == null) return false;
  try {
    final data = parseEnrollmentResponse(200, saved);
    final erp = Uri.tryParse(data['erp_url'] as String? ?? '');
    return erp != null && erp.scheme == 'https' && erp.host.isNotEmpty;
  } catch (_) {
    return false;
  }
}

Map<String, dynamic> parseEnrollmentResponse(int status, String body) {
  if (status != 200) {
    final message = switch (status) {
      400 =>
        'PIN invalid, expirat, deja folosit sau pentru alt tip de dispozitiv.',
      404 =>
        'Ruta de asociere nu există pe acest ERP. Verifică adresa și configurarea serverului.',
      429 =>
        'Prea multe încercări de asociere. Așteaptă 10 minute și generează un PIN nou.',
      401 || 403 =>
        'Serverul a refuzat accesul la asociere. Verifică configurarea autentificării.',
      _ =>
        'Serverul nu poate finaliza asocierea (HTTP $status). PIN-ul nu este neapărat invalid.',
    };
    throw EnrollmentRejected(status, message);
  }
  try {
    final data = jsonDecode(body);
    if (data is Map<String, dynamic> &&
        data['token'] is String &&
        (data['token'] as String).isNotEmpty &&
        data['device_id'] is String &&
        (data['device_id'] as String).isNotEmpty &&
        data['location_id'] is String &&
        (data['location_id'] as String).isNotEmpty) {
      return data;
    }
  } catch (_) {
    // Do not expose raw responses, which may contain credentials.
  }
  throw const FormatException(
    'Răspuns de asociere invalid. Verifică serverul ERP.',
  );
}

/// A successful trusted enrollment can direct the device to its own tenant ERP.
Uri enrolledErpAddress(Map<String, dynamic> data, Uri requestedOrigin) {
  final canonical = data['erp_url'];
  if (canonical == null) {
    if (requestedOrigin.origin == defaultEnrollmentOrigin) {
      throw const FormatException(
        'Cloud enrollment did not return a tenant ERP',
      );
    }
    return requestedOrigin;
  }
  if (canonical is! String || canonical != erpAddress(canonical).origin) {
    throw const FormatException('Invalid enrolled ERP origin');
  }
  return Uri.parse(canonical);
}

/// Old pairings and self-hosted servers keep their existing Auth proxy route.
Uri enrolledAuthAddress(Map<String, dynamic> data, Uri fallback) {
  final canonical = data['auth_url'];
  if (canonical == null) return erpAddress(fallback.origin);
  if (canonical is! String || canonical != erpAddress(canonical).origin) {
    throw const FormatException('Invalid enrolled Auth origin');
  }
  return Uri.parse(canonical);
}
