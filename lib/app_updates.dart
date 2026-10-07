import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'enrollment.dart';

class CompanionRelease {
  CompanionRelease(Map<String, dynamic> json, Uri erp)
    : versionCode = json['versionCode'] as int,
      versionName = json['versionName'] as String,
      size = json['size'] as int,
      digest = json['sha256'] as String,
      url = erp.resolve(json['path'] as String) {
    if (json['version'] != 1 || json['packageName'] != 'ro.tabusociety.chimera_companion' ||
        versionCode < 1 || versionName.length > 80 || size < 1 || size > 250 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) || url.scheme != 'https' ||
        url.origin != erp.origin || url.path != '/api/companion-updates/$digest.apk' ||
        url.hasQuery || url.hasFragment || url.userInfo.isNotEmpty) {
      throw const FormatException('Pachet de actualizare invalid.');
    }
  }
  final int versionCode, size;
  final String versionName, digest;
  final Uri url;
}

class CompanionUpdater {
  static const channel = MethodChannel('chimera/updates');
  Future<CompanionRelease?> check() async {
    if (!Platform.isAndroid) return null;
    final saved = await const FlutterSecureStorage().read(key: 'erp_pairing_v1');
    if (saved == null) return null;
    final erp = erpAddress(jsonDecode(saved)['erp_url'] as String);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(erp.resolve('/api/companion-updates/manifest'));
      request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200) throw const HttpException('Serverul de actualizări este indisponibil.');
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        bytes.addAll(chunk);
        if (bytes.length > 16384) throw const FormatException('Manifest prea mare.');
      }
      final release = CompanionRelease(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>, erp);
      final current = await channel.invokeMethod<int>('versionCode');
      return release.versionCode > (current ?? 0) ? release : null;
    } finally { client.close(force: true); }
  }

  Future<File> download(CompanionRelease release) async {
    final directory = Directory('${(await getTemporaryDirectory()).path}/updates');
    await directory.create(recursive: true);
    final file = File('${directory.path}/companion.apk.part');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final sink = file.openWrite();
    try {
      final request = await client.getUrl(release.url);
      request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw const HttpException('Descărcarea a eșuat.');
      var size = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        size += chunk.length;
        if (size > release.size) throw const FormatException('Dimensiune APK incorectă.');
        sink.add(chunk);
      }
      await sink.close();
      if (size != release.size || (await sha256.bind(file.openRead()).first).toString() != release.digest) {
        throw const FormatException('Integritatea APK-ului nu a putut fi verificată.');
      }
      return await file.rename('${directory.path}/companion.apk');
    } finally { client.close(force: true); await sink.close(); }
  }
}

class CompanionUpdateButton extends StatefulWidget {
  const CompanionUpdateButton({super.key, required this.isBusy, required this.setUpdating});
  final bool Function() isBusy;
  final void Function(bool) setUpdating;
  @override
  State<CompanionUpdateButton> createState() => _CompanionUpdateButtonState();
}

class _CompanionUpdateButtonState extends State<CompanionUpdateButton> {
  final updater = CompanionUpdater();
  CompanionRelease? release;
  Timer? timer;
  bool checking = false;
  String status = 'Verifică actualizările din ERP';
  @override
  void initState() {
    super.initState();
    unawaited(check());
    timer = Timer.periodic(const Duration(hours: 1), (_) => unawaited(check()));
  }
  Future<void> check() async {
    if (checking) return;
    checking = true;
    try {
      final next = await updater.check();
      if (mounted) setState(() { release = next; status = next == null ? 'Nu există o versiune mai nouă publicată în ERP.' : 'Versiunea ${next.versionName} (${next.versionCode}) este disponibilă.'; });
    } catch (_) {
      if (mounted) setState(() { status = 'Nu pot verifica actualizările. Verifică accesul la ERP și reîncearcă.'; });
    } finally { checking = false; }
  }
  @override
  void dispose() { timer?.cancel(); super.dispose(); }
  Future<void> open() async {
    if (widget.isBusy()) return;
    widget.setUpdating(true);
    try {
      await check();
      if (!mounted) return;
      var working = false;
      var message = status;
      File? downloaded;
      final selected = release;
      await showDialog<void>(context: context, barrierDismissible: false, builder: (context) => StatefulBuilder(
        builder: (context, update) => PopScope(canPop: !working, child: AlertDialog(
          title: const Text('Actualizare Companion'),
          content: Text('$message\n\nÎnrolarea și configurarea se păstrează. Android va cere confirmarea instalării. Comenzile hardware sunt suspendate cât timp acest dialog este deschis.'),
          actions: [
            TextButton(onPressed: working ? null : () => Navigator.pop(context), child: const Text('Închide')),
            if (selected != null) FilledButton(onPressed: working ? null : () async {
              update(() { working = true; message = 'Descarc și verific APK-ul…'; });
              try {
                downloaded ??= await updater.download(selected);
                final installed = await CompanionUpdater.channel.invokeMethod<bool>('install', {'path': downloaded!.path, 'versionCode': selected.versionCode});
                if (context.mounted) update(() { message = installed == true ? 'Confirmă instalarea în fereastra Android. Dacă ai anulat, poți încerca din nou.' : 'Permite instalarea din Chimera Companion în setările Android, revino aici și apasă din nou Instalează.'; });
              } on PlatformException catch (error) {
                if (context.mounted) update(() { message = error.message ?? 'Instalarea nu a putut fi pornită.'; });
              } catch (_) {
                if (context.mounted) update(() { message = 'Actualizarea a eșuat. Versiunea curentă este păstrată. Reîncearcă.'; });
              } finally { if (context.mounted) update(() { working = false; }); }
            }, child: Text(working ? 'Se pregătește…' : 'Instalează')),
          ],
        )),
      ));
    } finally { widget.setUpdating(false); }
  }
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: release == null ? 'Actualizări aplicație' : 'Actualizare disponibilă',
    onPressed: widget.isBusy() ? null : open,
    icon: Badge(isLabelVisible: release != null, child: const Icon(Icons.system_update)),
  );
}
