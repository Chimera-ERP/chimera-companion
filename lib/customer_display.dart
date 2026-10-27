import 'package:flutter/services.dart';

Map<String, Object?> customerDisplayPresentation(dynamic value) {
  if (value is! Map) throw ArgumentError('Invalid customer page settings');
  final url = value['url'] ?? '';
  final parsed = url is String ? Uri.tryParse(url) : null;
  if (url is! String ||
      url.length > 2048 ||
      (url.isNotEmpty &&
          (parsed == null ||
              parsed.scheme != 'https' ||
              parsed.host.isEmpty ||
              parsed.userInfo.isNotEmpty ||
              parsed.hasFragment))) {
    throw ArgumentError(
      'Customer page requires HTTPS without credentials or fragment',
    );
  }
  for (final field in ['title', 'message']) {
    final text = value[field];
    if (text is! String ||
        text.length > (field == 'title' ? 60 : 160) ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
      throw ArgumentError('Invalid customer page text');
    }
  }
  if (!RegExp(
        r'^#[0-9a-fA-F]{6}$',
      ).hasMatch(value['accent'] is String ? value['accent'] : '') ||
      !['light', 'dark'].contains(value['theme'])) {
    throw ArgumentError('Invalid customer page theme');
  }
  return {
    for (final field in ['url', 'title', 'message', 'accent', 'theme'])
      field: value[field] ?? '',
  };
}

/// Public basket information only. Prices are supplied by the POS quote engine.
Map<String, Object?> customerDisplayPayload(Map<String, dynamic> value) {
  final rows = value['lines'];
  final total = value['totalMinor'];
  final revision = value['revision'];
  final currency = value['currency'];
  if (rows is! List ||
      rows.length > 100 ||
      total is! int ||
      total < 0 ||
      total > 100000000000 ||
      revision is! int ||
      revision < 1 ||
      revision > 9007199254740991 ||
      currency is! String ||
      !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
    throw ArgumentError('Invalid customer display snapshot');
  }
  final lines = rows.map((row) {
    if (row is! Map ||
        row['name'] is! String ||
        (row['name'] as String).trim().isEmpty ||
        (row['name'] as String).length > 160 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(row['name']) ||
        row['quantity'] is! num ||
        !(row['quantity'] as num).isFinite ||
        row['quantity'] <= 0 ||
        row['quantity'] > 1000000 ||
        row['totalMinor'] is! int ||
        row['totalMinor'] < 0 ||
        row['totalMinor'] > 100000000000) {
      throw ArgumentError('Invalid customer display line');
    }
    return <String, Object?>{
      'name': row['name'],
      'quantity': row['quantity'],
      'totalMinor': row['totalMinor'],
    };
  }).toList();
  if (lines.isEmpty && total != 0) {
    throw ArgumentError('Empty basket must have zero total');
  }
  return {
    'revision': revision,
    'currency': currency,
    'totalMinor': total,
    'lines': lines,
    if (value.containsKey('presentation'))
      'presentation': customerDisplayPresentation(value['presentation']),
  };
}

class CustomerDisplay {
  static const channel = MethodChannel('chimera/customer-display');
  Future<Map<String, Object?>> status() async {
    try {
      return Map<String, Object?>.from(
        await channel.invokeMapMethod<String, dynamic>('status') ?? {},
      );
    } on MissingPluginException {
      return {'state': 'unsupported', 'enabled': false, 'displays': <Object>[]};
    }
  }

  Future<Map<String, Object?>> update(Map<String, dynamic> payload) async {
    final safe = customerDisplayPayload(payload);
    // posId is supplied by the verified transport, never the browser payload.
    if (payload['posId'] is! String || (payload['posId'] as String).isEmpty) {
      throw ArgumentError('Verified POS required');
    }
    return Map<String, Object?>.from(
      await channel.invokeMapMethod<String, dynamic>('update', {
            ...safe,
            'posId': payload['posId'],
          }) ??
          {},
    );
  }

  Future<void> setEnabled(bool enabled) =>
      channel.invokeMethod<void>('enable', {'enabled': enabled});
  Future<void> useBundle(String? directory) =>
      channel.invokeMethod<void>('bundle', {'directory': directory});
  Future<void> requestPermission() => channel.invokeMethod<void>('permission');
}
