import 'dart:convert';
import 'dart:io';

import 'package:chimera_companion/update_release.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class Transport implements ReleaseTransport {
  Transport(this.responses);
  final List<ReleaseResponse> responses;
  final calls = <Uri>[];
  @override
  Future<ReleaseResponse> get(Uri uri) async {
    calls.add(uri);
    return responses.removeAt(0);
  }

  @override
  void close() {}
}

ReleaseResponse response(List<int> bytes) =>
    ReleaseResponse(200, Stream.value(bytes));
ReleaseResponse redirect(String url) =>
    ReleaseResponse(302, const Stream.empty(), location: url);
final apk = utf8.encode('synthetic APK bytes');
Map<String, dynamic> manifest() => {
  'version': 1,
  'packageName': 'ro.tabusociety.chimera_companion',
  'versionCode': 46,
  'versionName': '0.1.44',
  'size': apk.length,
  'sha256': sha256.convert(apk).toString(),
  'signingCertificateSha256': companionSigningCertificate,
  'url':
      'https://github.com/$companionReleaseRepository/releases/download/v0.1.44/companion-0.1.44.apk',
};

void main() {
  test(
    'follows latest release and signed GitHub CDN without enrollment or credentials',
    () async {
      final transport = Transport([
        redirect(
          'https://github.com/$companionReleaseRepository/releases/download/v0.1.44/companion-update.json',
        ),
        redirect(
          'https://release-assets.githubusercontent.com/github-production-release-asset/file?sig=synthetic',
        ),
        response(utf8.encode(jsonEncode(manifest()))),
      ]);
      final release = await GitHubReleaseClient(transport: transport).check(45);
      expect(release?.versionCode, 46);
      expect(transport.calls.first, companionReleaseManifest);
      expect(transport.calls, hasLength(3));
    },
  );

  for (final current in [46, 47]) {
    test('does not reinstall or downgrade build $current', () async {
      final client = GitHubReleaseClient(
        transport: Transport([response(utf8.encode(jsonEncode(manifest())))]),
      );
      expect(await client.check(current), isNull);
    });
  }
  for (final url in [
    'http://github.com/$companionReleaseRepository/releases/download/v0.1.44/companion-update.json',
    'https://github.com/attacker/repo/releases/download/v0.1.44/companion-update.json',
    'https://github.com.evil.test/release',
    'https://evil.test/file',
    'https://user@release-assets.githubusercontent.com/file',
    'https://release-assets.githubusercontent.com:444/file',
  ]) {
    test('rejects untrusted redirect $url before contacting it', () async {
      final transport = Transport([redirect(url)]);
      await expectLater(
        GitHubReleaseClient(transport: transport).check(45),
        throwsFormatException,
      );
      expect(transport.calls, hasLength(1));
    });
  }
  test('bounds redirect chains and manifest size', () async {
    final endless = Transport(
      List.generate(
        4,
        (_) => redirect('https://release-assets.githubusercontent.com/file'),
      ),
    );
    await expectLater(
      GitHubReleaseClient(transport: endless).check(45),
      throwsA(isA<HttpException>()),
    );
    final large = Transport([response(List.filled(16385, 32))]);
    await expectLater(
      GitHubReleaseClient(transport: large).check(45),
      throwsFormatException,
    );
  });
  test('download verifies bytes before exposing installer file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'companion-release-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final release = CompanionRelease(manifest());
    final client = GitHubReleaseClient(
      transport: Transport([
        redirect(
          'https://release-assets.githubusercontent.com/file?sig=synthetic',
        ),
        response(apk),
      ]),
    );
    final file = await client.download(release, directory);
    expect(await file.readAsBytes(), apk);
    expect(await File('${directory.path}/companion.apk.part').exists(), false);
  });
  for (final bytes in [
    apk.sublist(1),
    [...apk, 0],
    List.filled(apk.length, 0),
  ]) {
    test(
      'rejects truncated, oversized or corrupt APK and removes partial file ${bytes.length}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'companion-release-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final client = GitHubReleaseClient(
          transport: Transport([response(bytes)]),
        );
        await expectLater(
          client.download(CompanionRelease(manifest()), directory),
          throwsFormatException,
        );
        expect(await directory.list().isEmpty, true);
      },
    );
  }
  for (final mutation in [
    {'signingCertificateSha256': 'wrong'},
    {'url': 'https://evil.test/app.apk'},
    {'versionName': '0.1.44-beta'},
    {'packageName': 'other'},
  ]) {
    test('rejects incompatible artifact identity $mutation', () {
      expect(
        () => CompanionRelease({...manifest(), ...mutation}),
        throwsFormatException,
      );
    });
  }
}
