import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

typedef DisplayDownload = Future<List<int>> Function(String path, int limit);
final _digestPattern = RegExp(r'^[a-f0-9]{64}$');

/// Content-addressed, private disk cache. The active pointer changes only after
/// every file verifies; an interrupted update cannot destroy the last good page.
class CustomerDisplayBundle {
  CustomerDisplayBundle(this.root, {required this.org, required this.location});
  final Directory root;
  final String org, location;
  String? key;
  int? get revision => _active?['revision'] as int?;
  Map<String, dynamic>? _active;
  Future<void> restore() async {
    try {
      final pointer = (await File('${root.path}/active').readAsString()).trim();
      if (!_digestPattern.hasMatch(pointer)) return;
      final manifest =
          jsonDecode(
                await File(
                  '${root.path}/$pointer/manifest.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      _validate(manifest);
      if (manifest['key'] != pointer) return;
      for (final item in _files(manifest)) {
        final bytes = await File(
          '${root.path}/$pointer/${item['name']}',
        ).readAsBytes();
        _verify(bytes, item);
      }
      key = pointer;
      _active = manifest;
    } catch (_) {
      key = null;
      _active = null;
    }
  }

  String? get directory => key == null ? null : '${root.path}/$key';
  void _validate(Map<String, dynamic> m) {
    if (m['schema'] != 1 ||
        m['orgId'] != org ||
        m['locationId'] != location ||
        m['key'] is! String ||
        !_digestPattern.hasMatch(m['key']) ||
        m['revision'] is! int ||
        m['revision'] < 1 ||
        m['config'] is! Map ||
        m['config']['version'] != 1 ||
        m['assets'] is! List ||
        (m['assets'] as List).length > 11) {
      throw const FormatException('Invalid presentation scope/version');
    }
    final files = _files(m);
    if (files.map((f) => f['name']).toSet().length != files.length) {
      throw const FormatException('Duplicate display asset');
    }
    var size = 0;
    for (final f in files) {
      if (f['sha256'] is! String ||
          !_digestPattern.hasMatch(f['sha256']) ||
          f['size'] is! int ||
          f['size'] < 1 ||
          f['size'] > (f['name'] == 'index.html' ? 131072 : 5242880)) {
        throw const FormatException('Invalid display file');
      }
      size += f['size'] as int;
    }
    if (size > 32 * 1024 * 1024) {
      throw const FormatException('Display bundle too large');
    }
    final config = m['config'] as Map, playlist = config['playlist'];
    if (playlist is! List ||
        playlist.length > 10 ||
        !['split', 'receipt', 'banner'].contains(config['layout'])) {
      throw const FormatException('Invalid display layout');
    }
    final assets = (m['assets'] as List).map((a) => a['sha256']).toSet();
    if (config['logoAsset'] != null && !assets.contains(config['logoAsset'])) {
      throw const FormatException('Missing logo');
    }
    for (final s in playlist) {
      if (s is! Map ||
          s['kind'] != 'image' ||
          !assets.contains(s['asset']) ||
          s['durationSeconds'] is! int ||
          s['durationSeconds'] < 5 ||
          s['durationSeconds'] > 120) {
        throw const FormatException('Invalid playlist');
      }
    }
  }

  List<Map<String, dynamic>> _files(Map<String, dynamic> m) => [
    {...Map<String, dynamic>.from(m['player'] as Map), 'name': 'index.html'},
    for (final raw in m['assets'] as List)
      {...Map<String, dynamic>.from(raw as Map), 'name': raw['sha256']},
  ];
  void _verify(List<int> bytes, Map<String, dynamic> f) {
    if (bytes.length != f['size'] ||
        sha256.convert(bytes).toString() != f['sha256']) {
      throw const FormatException('Display integrity mismatch');
    }
    if (f['name'] != 'index.html' &&
        ![
          'image/png',
          'image/jpeg',
          'image/webp',
          'image/gif',
        ].contains(f['mime'])) {
      throw const FormatException('Unsupported media type');
    }
  }

  Future<bool> install(
    Map<String, dynamic> manifest,
    DisplayDownload download,
  ) async {
    _validate(manifest);
    if (manifest['key'] == key) return false;
    // Never let an older response undo a newer publication in this scope.
    if (_active != null && manifest['revision'] < _active!['revision']) {
      throw const FormatException('Stale publication');
    }
    await root.create(recursive: true);
    final stage = await root.createTemp('pending-');
    try {
      for (final f in _files(manifest)) {
        List<int>? bytes;
        if (directory != null) {
          try {
            bytes = await File('$directory/${f['name']}').readAsBytes();
            _verify(bytes, f);
          } catch (_) {
            bytes = null;
          }
        }
        bytes ??= await download(
          f['name'] == 'index.html'
              ? 'player/${f['sha256']}'
              : 'media/${f['sha256']}',
          f['size'] as int,
        );
        _verify(bytes, f);
        await File(
          '${stage.path}/${f['name']}',
        ).writeAsBytes(bytes, flush: true);
      }
      await File(
        '${stage.path}/manifest.json',
      ).writeAsString(jsonEncode(manifest), flush: true);
      final destination = Directory('${root.path}/${manifest['key']}');
      // Only a validated, exact content-addressed cache directory is replaced.
      if (await destination.exists()) await destination.delete(recursive: true);
      await stage.rename(destination.path);
      final pending = File('${root.path}/active.pending');
      await pending.writeAsString(manifest['key'] as String, flush: true);
      await pending.rename('${root.path}/active');
      final previous = key;
      key = manifest['key'] as String;
      _active = manifest;
      // Retain current + previous; bounded disk usage even across many releases.
      await for (final entry in root.list()) {
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (entry is Directory &&
            name != key &&
            name != previous &&
            (_digestPattern.hasMatch(name) || name.startsWith('pending-'))) {
          await entry.delete(recursive: true);
        }
      }
      return true;
    } finally {
      if (await stage.exists()) await stage.delete(recursive: true);
    }
  }
}
