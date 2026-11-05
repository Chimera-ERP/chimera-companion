import 'companion_scene.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:permission_handler/permission_handler.dart';
import 'companion_app_bar.dart';
import 'scale_service.dart';
import 'android_settings.dart';
import 'peripheral_wizard.dart';

class ScalePage extends StatefulWidget {
  const ScalePage({super.key, required this.service, this.embedded = false});
  final ScaleService service;
  final bool embedded;
  @override
  State<ScalePage> createState() => _ScalePageState();
}

class _ScalePageState extends State<ScalePage> {
  Timer? _freshness;
  @override
  void initState() {
    super.initState();
    unawaited(widget.service.restore());
    _freshness = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _freshness?.cancel();
    unawaited(widget.service.stopScan());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.embedded
      ? _content()
      : Scaffold(
          appBar: const CompanionAppBar(title: Text('Cântar Bluetooth')),
          body: SafeArea(child: _content()),
        );

  Widget _content() => AnimatedBuilder(
    animation: widget.service,
    builder: (context, _) {
      final service = widget.service;
      final current = service.reading;
      final fresh =
          current != null &&
          DateTime.now().difference(current.observedAt) <=
              const Duration(seconds: 2);
      return SingleChildScrollView(
        physics: widget.embedded ? const NeverScrollableScrollPhysics() : null,
        padding: widget.embedded ? EdgeInsets.zero : const EdgeInsets.all(20),
        child: PeripheralWizard(
          scene: CompanionSceneState.scale,
          showScene: !widget.embedded,
          transport: 'Bluetooth',
          ready: service.state.name == 'ready',
          busy: service.connecting,
          summary: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(service.selectedName ?? 'Cântar'),
              Text(
                service.state.name == 'ready'
                    ? 'Conectat · ${fresh ? '${current.net} g' : 'aștept greutatea'}'
                    : service.error ?? 'Conexiune indisponibilă',
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (service.selectedId != null) ...[
                Text(
                  service.selectedName ?? 'Acaia',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  service.connecting
                      ? 'Conectare…'
                      : switch (service.state.name) {
                          'ready' => 'Conectat',
                          'error' => 'Eroare de conectare',
                          _ => 'Deconectat',
                        },
                ),
                const SizedBox(height: 16),
                Text(
                  !fresh ? '— g' : '${current.net} g',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const Text(
                  'Unitatea se configurează automat. Confirmă greutatea în POS.',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FButton(
                      onPress: service.connecting
                          ? null
                          : () => service.connect(
                              service.selectedId!,
                              service.selectedName!,
                            ),
                      child: const Text('Reconectează'),
                    ),
                    FButton(
                      onPress: service.connecting ? null : service.forget,
                      child: const Text('Deconectează și uită'),
                    ),
                  ],
                ),
                const Divider(height: 32),
              ],
              FButton(
                onPress: service.scanning || service.connecting
                    ? null
                    : service.scan,
                child: Text(
                  service.scanning ? 'Caut cântare…' : 'Caută cântar',
                ),
              ),
              if (service.scanning)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (service.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    service.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (!service.scanning &&
                  service.devices.isEmpty &&
                  service.selectedId == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Pornește cântarul și caută. Modelele Acaia sunt identificate automat.',
                  ),
                ),
              for (final device in service.devices.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(device.name.isEmpty ? 'Acaia' : device.name),
                  subtitle: Text('${device.id} · ${device.rssi} dBm'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: service.connecting
                      ? null
                      : () => service.connect(device.id, device.name),
                ),
              TextButton(
                onPressed: () => AndroidSettings.open('bluetooth'),
                child: const Text('Setări Bluetooth'),
              ),
              TextButton(
                onPressed: openAppSettings,
                child: const Text('Permisiuni Android'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
