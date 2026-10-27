import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/customer_display_bundle.dart';

void main() {
  late Directory root;
  final page = utf8.encode('<html>display</html>'),
      image = utf8.encode('synthetic image');
  final imageHash = sha256.convert(image).toString();
  Map<String, dynamic> manifest(int revision) => {
    'schema': 1,
    'key': sha256.convert(utf8.encode('release $revision')).toString(),
    'orgId': 'org',
    'locationId': 'location',
    'revision': revision,
    'player': {'sha256': sha256.convert(page).toString(), 'size': page.length},
    'assets': [
      {'sha256': imageHash, 'size': image.length, 'mime': 'image/gif'},
    ],
    'config': {
      'version': 1,
      'layout': 'split',
      'logoAsset': imageHash,
      'playlist': [
        {'kind': 'image', 'asset': imageHash, 'durationSeconds': 5},
      ],
    },
  };
  Future<List<int>> download(String path, int limit) async =>
      path.startsWith('player/') ? page : image;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('display-bundle-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  CustomerDisplayBundle create() =>
      CustomerDisplayBundle(root, org: 'org', location: 'location');
  test(
    'all assets available after cold offline restore, without any network',
    () async {
      final cache = create();
      expect(await cache.install(manifest(1), download), isTrue);
      final restarted = create();
      await restarted.restore();
      expect(restarted.key, cache.key);
      expect(restarted.revision, 1);
      expect(
        await File('${restarted.directory}/$imageHash').readAsBytes(),
        image,
      );
    },
  );
  test(
    'failed next download preserves active pointer and previous content',
    () async {
      final cache = create();
      await cache.install(manifest(1), download);
      final oldKey = cache.key;
      final changed = manifest(2);
      changed['player'] = {'sha256': 'a' * 64, 'size': 20};
      await expectLater(
        cache.install(
          changed,
          (path, limit) async => throw const SocketException('offline'),
        ),
        throwsA(isA<SocketException>()),
      );
      final restarted = create();
      await restarted.restore();
      expect(restarted.key, oldKey);
    },
  );
  test(
    'hash mismatch, oversized bundle and foreign location cannot activate',
    () async {
      final cache = create();
      await expectLater(
        cache.install(manifest(1), (path, limit) async => [1, 2, 3]),
        throwsFormatException,
      );
      expect(cache.key, isNull);
      final foreign = manifest(1)..['locationId'] = 'foreign';
      await expectLater(
        cache.install(foreign, download),
        throwsFormatException,
      );
      final tooLarge = manifest(1);
      tooLarge['assets'][0]['size'] = 5242881;
      await expectLater(
        cache.install(tooLarge, download),
        throwsFormatException,
      );
    },
  );
  test(
    'same revision is idempotent; older publication is rejected; cache stays bounded',
    () async {
      final cache = create();
      await cache.install(manifest(1), download);
      expect(
        await cache.install(
          manifest(1),
          (p, l) async => throw StateError('must not fetch'),
        ),
        isFalse,
      );
      await cache.install(manifest(2), download);
      await cache.install(manifest(3), download);
      await expectLater(
        cache.install(manifest(1), download),
        throwsFormatException,
      );
      expect(await root.list().where((f) => f is Directory).length, 2);
    },
  );
  test('tampered disk asset is not silently restored', () async {
    final cache = create();
    await cache.install(manifest(1), download);
    await File('${cache.directory}/$imageHash').writeAsString('corrupt');
    final restarted = create();
    await restarted.restore();
    expect(restarted.key, isNull);
  });
  test('missing image and unsafe filename fail before download', () async {
    final cache = create(), missing = manifest(1);
    missing['config']['logoAsset'] = 'b' * 64;
    await expectLater(cache.install(missing, download), throwsFormatException);
    final traversal = manifest(1);
    traversal['assets'][0]['sha256'] = '../../secret';
    await expectLater(
      cache.install(traversal, download),
      throwsFormatException,
    );
  });
}
