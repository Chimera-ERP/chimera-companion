import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../companion_app_bar.dart';
import 'production_print.dart';
import '../peripheral_wizard.dart';
import 'niimbot_ble.dart';
import 'niimbot_protocol.dart';
import 'package:permission_handler/permission_handler.dart';

class PrinterSettingsPage extends StatefulWidget {
  const PrinterSettingsPage({
    super.key,
    this.embedded = false,
    this.onSaved,
    this.discovery,
  });
  final NiimbotDiscovery? discovery;
  final bool embedded;
  final VoidCallback? onSaved;
  @override
  State<PrinterSettingsPage> createState() => _PrinterSettingsPageState();
}

class _PrinterSettingsPageState extends State<PrinterSettingsPage> {
  static const storage = FlutterSecureStorage();
  final fields = {
    for (final entry in {
      'name': 'Production printer',
      'host': '',
      'port': '9100',
      'widthDots': '576',
      'heightDots': '800',
    }.entries)
      entry.key: TextEditingController(text: entry.value),
  };
  String protocol = 'escpos';
  String? feedback;
  bool loading = true, saving = false;
  late final discovery = widget.discovery ?? NiimbotDiscovery();
  String? bluetoothId;
  int? modelId;
  @override
  void initState() {
    super.initState();
    discovery.addListener(_changed);
    _restore();
  }

  void _changed() {
    if (!mounted) return;
    if (discovery.model != null && discovery.selectedId != null) {
      if (bluetoothId != discovery.selectedId ||
          modelId != discovery.model!.id) {
        bluetoothId = discovery.selectedId;
        modelId = discovery.model!.id;
        fields['name']!.text = 'NIIMBOT ${discovery.model!.name}';
        fields['widthDots']!.text = '${discovery.model!.width}';
      }
    }
    setState(() {});
  }

  Future<void> _restore() async {
    try {
      final saved = await storage.read(key: 'production_printer_v1');
      if (saved != null) {
        final config = PrinterConfig.fromJson(jsonDecode(saved));
        for (final field in fields.entries) {
          field.value.text = '${config.toJson()[field.key]}';
        }
        protocol = config.protocol;
        if (protocol == 'niimbot') {
          bluetoothId = config.host.substring(4);
          modelId = config.modelId;
        }
      }
    } catch (_) {
      feedback = 'Configurația nu poate fi citită. Verifică valorile.';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _save() async {
    setState(() {
      saving = true;
      feedback = null;
    });
    try {
      final config = _config();
      await storage.write(
        key: 'production_printer_v1',
        value: jsonEncode(config.toJson()),
      );
      if (mounted) {
        widget.onSaved?.call();
        setState(
          () => feedback =
              'Salvat. Asociază imprimanta în ERP. Diagnosticul necesită autorizare ERP; nu s-a imprimat nimic.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback =
              'Adresă IPv4 LAN privată, port 1–65535, lățime 320–832 și înălțime 480–2400 puncte.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  PrinterConfig _config() => PrinterConfig.fromJson({
    'name': fields['name']!.text.trim(),
    'protocol': protocol,
    'host': protocol == 'niimbot'
        ? 'ble:${bluetoothId?.toUpperCase()}'
        : fields['host']!.text.trim(),
    'port': protocol == 'niimbot' ? 0 : int.parse(fields['port']!.text),
    if (protocol == 'niimbot') 'modelId': modelId,
    for (final key in ['widthDots', 'heightDots'])
      key: int.parse(fields[key]!.text),
  });
  bool _validate() {
    try {
      _config();
      setState(() => feedback = null);
      return true;
    } catch (_) {
      setState(
        () => feedback = protocol == 'niimbot'
            ? 'Selectează o imprimantă identificată. Lățimea trebuie să fie multiplu de 8, maximum lățimea capului; înălțime 64–2400 puncte.'
            : 'Adresă IPv4 LAN privată, port 1–65535, lățime 320–832 și înălțime 480–2400 puncte.',
      );
      return false;
    }
  }

  @override
  void dispose() {
    discovery.removeListener(_changed);
    if (widget.discovery == null) discovery.dispose();
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.embedded
      ? _content()
      : Scaffold(
          appBar: CompanionAppBar(
            title: const Text('Imprimantă producție'),
            busy: saving,
          ),
          body: _content(),
        );

  Widget _content() => loading
      ? const Center(child: CircularProgressIndicator())
      : SingleChildScrollView(
          physics: widget.embedded
              ? const NeverScrollableScrollPhysics()
              : null,
          padding: widget.embedded ? EdgeInsets.zero : const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: PeripheralWizard(
                transport: protocol == 'niimbot' ? 'Bluetooth' : 'LAN',
                transports: const ['Bluetooth', 'LAN'],
                onTransport: (type) => setState(() {
                  protocol = type == 'Bluetooth' ? 'niimbot' : 'escpos';
                  feedback = null;
                }),
                ready: protocol != 'niimbot' || bluetoothId != null,
                busy: saving || discovery.scanning || discovery.connecting,
                validate: _validate,
                finish: _save,
                summary: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(fields['name']!.text),
                    Text(
                      protocol == 'niimbot'
                          ? '${bluetoothId ?? "Neselectată"} · NIIMBOT ${modelId == null ? "" : NiimbotModel.fromId(modelId!).name}'
                          : '${fields['host']!.text}:${fields['port']!.text} · $protocol',
                    ),
                    const Text(
                      'Configurare locală. Nu se imprimă nimic; verificarea fizică se face separat din ERP.',
                    ),
                    if (feedback != null) Text(feedback!),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      protocol == 'niimbot'
                          ? 'Etichete NIIMBOT cu spațiu între etichete. Dimensiunile trebuie să corespundă rolei; nu se imprimă la conectare.'
                          : 'Tichete ESC/POS sau etichete ZPL prin LAN. Trimiterea nu confirmă imprimarea fizică.',
                    ),
                    const SizedBox(height: 16),
                    if (protocol == 'niimbot') ...[
                      OutlinedButton.icon(
                        onPressed: discovery.scanning || discovery.connecting
                            ? null
                            : discovery.scan,
                        icon: const Icon(Icons.bluetooth_searching),
                        label: Text(
                          discovery.scanning ? 'Se caută…' : 'Caută imprimante',
                        ),
                      ),
                      if (discovery.scanning || discovery.connecting)
                        const LinearProgressIndicator(),
                      for (final device in discovery.devices.values)
                        ListTile(
                          title: Text(
                            device.name.isEmpty ? 'NIIMBOT' : device.name,
                          ),
                          subtitle: Text(device.id),
                          trailing: bluetoothId == device.id
                              ? const Icon(Icons.check)
                              : null,
                          onTap: discovery.connecting
                              ? null
                              : () => discovery.select(device.id),
                        ),
                      if (!discovery.scanning && discovery.devices.isEmpty)
                        const Text(
                          'Pornește imprimanta și caută. Închide alte aplicații conectate la ea.',
                        ),
                      if (bluetoothId != null) Text('Selectată: $bluetoothId'),
                      if (discovery.error != null) ...[
                        Text(
                          discovery.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        TextButton(
                          onPressed: openAppSettings,
                          child: const Text('Permisiuni aplicație'),
                        ),
                      ],
                    ] else
                      DropdownButtonFormField<String>(
                        initialValue: protocol,
                        decoration: const InputDecoration(
                          labelText: 'Protocol',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'escpos',
                            child: Text('ESC/POS · tichet'),
                          ),
                          DropdownMenuItem(
                            value: 'zpl',
                            child: Text('ZPL · etichetă'),
                          ),
                        ],
                        onChanged: saving
                            ? null
                            : (value) => setState(() => protocol = value!),
                      ),
                    for (final entry in fields.entries.where(
                      (e) =>
                          protocol != 'niimbot' ||
                          !['host', 'port'].contains(e.key),
                    ))
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: TextField(
                          controller: entry.value,
                          enabled: !saving,
                          keyboardType:
                              [
                                'port',
                                'widthDots',
                                'heightDots',
                              ].contains(entry.key)
                              ? TextInputType.number
                              : TextInputType.text,
                          decoration: InputDecoration(
                            labelText: const {
                              'name': 'Nume imprimantă',
                              'host': 'Adresă IPv4 LAN',
                              'port': 'Port',
                              'widthDots': 'Lățime (puncte)',
                              'heightDots': 'Înălțime etichetă (puncte)',
                            }[entry.key],
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    if (feedback != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(feedback!),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
}
