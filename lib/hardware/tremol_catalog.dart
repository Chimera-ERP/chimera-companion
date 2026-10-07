import 'dart:convert';
import 'dart:io';

class TremolCommandDefinition {
  const TremolCommandDefinition(this.name, this.description, this.definition);
  final String name;
  final String description;
  final String definition;
}

/// Catalog discovery only: never execute arbitrary URLs supplied by ERP/POS.
class TremolCatalogClient {
  TremolCatalogClient(this.baseUrl) {
    if (!['http', 'https'].contains(baseUrl.scheme) ||
        baseUrl.host.isEmpty ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment ||
        !['', '/'].contains(baseUrl.path)) {
      throw ArgumentError(
        'Use a Direct API origin, without credentials or path',
      );
    }
  }
  final Uri baseUrl;

  Future<List<TremolCommandDefinition>> discover() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .getUrl(baseUrl.resolve('/getcmds'))
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != 200) {
        throw HttpException('Catalog HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        bytes.addAll(chunk);
        if (bytes.length > 2000000) {
          throw const FormatException('Catalog too large');
        }
      }
      return parse(utf8.decode(bytes));
    } finally {
      client.close(force: true);
    }
  }

  static List<TremolCommandDefinition> parse(String source) {
    final value = jsonDecode(source);
    if (value is! List) {
      throw const FormatException('Expected a command catalog');
    }
    return value
        .map((item) {
          if (item is! Map ||
              item['Name'] is! String ||
              item['Doc'] is! String) {
            throw const FormatException('Malformed Tremol definition');
          }
          return TremolCommandDefinition(
            item['Name'] as String,
            item['FpOperation'] is String ? item['FpOperation'] as String : '',
            item['Doc'] as String,
          );
        })
        .toList(growable: false);
  }
}
