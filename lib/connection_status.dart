import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'debug_panel.dart';
import 'hardware/connection.dart';
import 'hardware/datecs_device_client.dart';
import 'hardware/tremol_adapter.dart';

class ConnectionStatusPanel extends StatefulWidget {
  const ConnectionStatusPanel({super.key});
  @override
  State<ConnectionStatusPanel> createState() => _ConnectionStatusPanelState();
}

class _ConnectionStatusPanelState extends State<ConnectionStatusPanel>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _busy = false;
  final _states = <String, bool?>{'ECR': null, 'POS': null, 'Chimera': null};
  String _description = 'Conexiunile nu sunt încă verificate.';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (_busy ||
        !mounted ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    setState(() {
      _busy = true;
      _states.updateAll((_, _) => null);
    });
    const storage = FlutterSecureStorage();
    final states = <String, bool?>{'ECR': null, 'POS': null, 'Chimera': null};
    final details = <String>[];
    try {
      final saved = await storage.read(key: 'local_hardware_v1');
      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        final endpoint = LanEndpoint(
          host: data['host'] as String,
          port: int.parse(data['port'] as String),
        );
        if (data['model'] == 'datecsDp25') {
          final result = await DatecsDeviceClient(
            endpoint,
            profile: DatecsProfile.values.byName(
              data['datecsProfile'] as String? ?? 'auto',
            ),
          ).inspect();
          states['ECR'] = result.ready;
          details.add(result.description);
        } else {
          final result = await TremolAdapter(
            FiscalConnection(
              id: 'local-ecr',
              model: FiscalModel.values.byName(data['model'] as String),
              endpoint: endpoint,
              operatorNumber: int.parse(data['operator'] as String),
              operatorPassword: data['password'] as String,
              tcpPassword: data['tcpPassword'] as String? ?? '',
              cashPaymentCode: data['cashCode'] as String,
              cardPaymentCode: data['cardCode'] as String,
              tillNumber: data['till'] as String,
            ),
          ).readStatus();
          states['ECR'] = result.ready;
          details.add(result.description);
        }
      } else {
        details.add('ECR neconfigurat');
      }
    } catch (_) {
      states['ECR'] = false;
      details.add('ECR indisponibil');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final saved = await storage.read(key: 'erp_pairing_v1');
      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        final request = await client.getUrl(
          Uri.parse(
            data['erp_url'] as String,
          ).resolve('/api/devices/companion/status'),
        );
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${data['token']}',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        if (response.statusCode != 200) {
          throw const HttpException('Connection rejected');
        }
        final body =
            jsonDecode(
                  await utf8.decoder
                      .bind(response)
                      .join()
                      .timeout(const Duration(seconds: 5)),
                )
                as Map<String, dynamic>;
        if (body['location_id'] != data['location_id'] ||
            body['pos_recently_active'] is! bool) {
          throw const FormatException('Invalid connection status');
        }
        states['Chimera'] = true;
        states['POS'] = body['pos_recently_active'] as bool;
        details.add('Chimera conectat · ${body['location_name']}');
        details.add(
          states['POS'] == true
              ? 'POS activ în ultimele 2 minute'
              : 'Niciun POS activ recent în această locație',
        );
      } else {
        details.add('Chimera neasociat · POS neverificat');
      }
    } catch (_) {
      states['Chimera'] = false;
      details.add('Chimera indisponibil / asociere invalidă; POS neverificat');
    } finally {
      client.close(force: true);
    }
    if (!mounted) return;
    setState(() {
      _states.addAll(states);
      _description = details.join('\n');
      _busy = false;
    });
    debugLog(_description);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ConnectionIndicators(states: _states),
      const SizedBox(height: 12),
      ExpansionTile(
        title: const Text('Detalii conexiuni', style: TextStyle(fontSize: 13)),
        children: [
          Text(
            _description,
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ],
      ),
      TextButton.icon(
        onPressed: _busy ? null : _check,
        icon: const Icon(Icons.refresh, size: 16),
        label: Text(_busy ? 'Verific…' : 'Verifică conexiunile'),
      ),
      const Divider(),
    ],
  );
}

/// Pure presentation: rotation changes layout without restarting health checks.
class ConnectionIndicators extends StatelessWidget {
  const ConnectionIndicators({super.key, required this.states});
  final Map<String, bool?> states;

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    Widget indicator(MapEntry<String, bool?> entry) {
      final idlePos = entry.key == 'POS' && entry.value == false;
      final color = entry.value == true
          ? const Color(0xff69d5b1)
          : idlePos
          ? const Color(0xffa3b3c9)
          : entry.value == false
          ? const Color(0xfff3b878)
          : const Color(0xffa3b3c9);
      final circle = Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: .12),
          border: Border.all(color: color.withValues(alpha: .25)),
        ),
        child: Icon(switch (entry.key) {
          'ECR' => Icons.receipt_long_outlined,
          'POS' => Icons.point_of_sale_outlined,
          _ => Icons.cloud_outlined,
        }, color: color),
      );
      final label = Column(
        crossAxisAlignment: portrait
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Text(switch (entry.key) {
            'ECR' => 'Casă de marcat',
            'POS' => 'Aplicația POS',
            _ => 'Chimera ERP',
          }, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(
            entry.value == true
                ? (entry.key == 'POS'
                      ? 'Activ recent · în această locație'
                      : 'Conexiune verificată')
                : idlePos
                ? 'Fără activitate recentă'
                : entry.value == false
                ? 'Conexiune indisponibilă'
                : 'Neverificat',
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      );
      return portrait
          ? Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xff161d27),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: .06)),
              ),
              child: Row(
                children: [
                  circle,
                  const SizedBox(width: 16),
                  Expanded(child: label),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
            )
          : Column(children: [circle, const SizedBox(height: 12), label]);
    }

    return portrait
        ? Column(children: states.entries.map(indicator).toList())
        : Row(
            children: states.entries
                .map((entry) => Expanded(child: indicator(entry)))
                .toList(),
          );
  }
}
