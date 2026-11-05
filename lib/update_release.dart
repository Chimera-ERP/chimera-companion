import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const companionReleaseRepository = 'Chimera-ERP/chimera-companion';
const companionSigningCertificate =
    '7b6ea16440c3928bc2402d9393de778c9a76a47c37e637ce898fcb8036809933';
final companionReleaseManifest = Uri.https(
  'github.com',
  '/$companionReleaseRepository/releases/latest/download/companion-update.json',
);

class CompanionRelease {
  CompanionRelease(Map<String, dynamic> json)
    : versionCode = json['versionCode'] as int,
      versionName = json['versionName'] as String,
      size = json['size'] as int,
      digest = json['sha256'] as String,
      url = Uri.parse(json['url'] as String) {
    if (json['version'] != 1 ||
        json['packageName'] != 'ro.tabusociety.chimera_companion' ||
        json['signingCertificateSha256'] != companionSigningCertificate ||
        versionCode < 1 ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(versionName) ||
        size < 1 ||
        size > 250 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        url !=
            Uri.https(
              'github.com',
              '/$companionReleaseRepository/releases/download/v$versionName/companion-$versionName.apk',
            )) {
      throw const FormatException('Invalid Companion release');
    }
  }
  final int versionCode, size;
  final String versionName, digest;
  final Uri url;
}

class ReleaseResponse {
  const ReleaseResponse(this.status, this.body, {this.location});
  final int status;
  final Stream<List<int>> body;
  final String? location;
}

abstract interface class ReleaseTransport {
  Future<ReleaseResponse> get(Uri uri);
  void close();
}

class IoReleaseTransport implements ReleaseTransport {
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  @override
  Future<ReleaseResponse> get(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Chimera-Companion-Updater',
    );
    final response = await request.close();
    return ReleaseResponse(
      response.statusCode,
      response,
      location: response.headers.value(HttpHeaders.locationHeader),
    );
  }

  @override
  void close() => _client.close(force: true);
}

/// GitHub is the only release authority. CDN redirects never receive credentials.
class GitHubReleaseClient {
  GitHubReleaseClient({ReleaseTransport? transport})
    : _transport = transport ?? IoReleaseTransport();
  final ReleaseTransport _transport;

  bool _allowedRedirect(Uri uri, Uri source) {
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return false;
    }
    if (uri.host == 'release-assets.githubusercontent.com') return true;
    if (uri.host != 'github.com' || uri.hasQuery) return false;
    if (source != companionReleaseManifest) return uri == source;
    return RegExp(
      '^/${RegExp.escape(companionReleaseRepository)}/releases/download/v[0-9]+\\.[0-9]+\\.[0-9]+/companion-update\\.json\$',
    ).hasMatch(uri.path);
  }

  Future<Stream<List<int>>> _get(Uri source) async {
    var uri = source;
    for (var redirects = 0; redirects <= 3; redirects++) {
      final response = await _transport
          .get(uri)
          .timeout(const Duration(seconds: 20));
      if (response.status == 200) {
        return response.body.timeout(const Duration(seconds: 30));
      }
      if (![301, 302, 303, 307, 308].contains(response.status) ||
          response.location == null ||
          redirects == 3) {
        throw const HttpException('Release download unavailable');
      }
      final next = uri.resolve(response.location!);
      if (!_allowedRedirect(next, source)) {
        throw const FormatException('Untrusted release redirect');
      }
      // Do not buffer an untrusted redirect body.
      await response.body.listen(null).cancel();
      uri = next;
    }
    throw const HttpException('Too many release redirects');
  }

  Future<CompanionRelease?> check(int installedVersion) async {
    if (installedVersion < 1) {
      throw const FormatException('Unknown installed version');
    }
    final bytes = <int>[];
    await for (final chunk in await _get(companionReleaseManifest)) {
      if (bytes.length + chunk.length > 16384) {
        throw const FormatException('Release manifest too large');
      }
      bytes.addAll(chunk);
    }
    final release = CompanionRelease(
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
    );
    return release.versionCode > installedVersion ? release : null;
  }

  Future<File> download(CompanionRelease release, Directory directory) async {
    await directory.create(recursive: true);
    final part = File('${directory.path}/companion.apk.part');
    final sink = part.openWrite();
    try {
      var size = 0;
      await for (final chunk in await _get(release.url)) {
        size += chunk.length;
        if (size > release.size) {
          throw const FormatException('Incorrect APK size');
        }
        sink.add(chunk);
      }
      await sink.close();
      if (size != release.size ||
          (await sha256.bind(part.openRead()).first).toString() !=
              release.digest) {
        throw const FormatException('APK integrity verification failed');
      }
      return await part.rename('${directory.path}/companion.apk');
    } finally {
      await sink.close();
      if (await part.exists()) await part.delete();
    }
  }

  void close() => _transport.close();
}
