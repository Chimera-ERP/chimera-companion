import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'niimbot_ble.dart';
import 'niimbot_protocol.dart';
import '../hardware/command_executor.dart';
import '../hardware/command_journal.dart';
import '../hardware/contracts.dart';

const productionPrintOperations = [
  'productionWorkTicket',
  'productionLabel',
  'productionPrintDiagnostic',
];

class PrinterConfig {
  PrinterConfig.fromJson(Map<String, dynamic> value)
    : name = value['name'] as String,
      protocol = value['protocol'] as String,
      host = value['host'] as String,
      port = value['port'] as int,
      widthDots = value['widthDots'] as int,
      heightDots = value['heightDots'] as int,
      modelId = value['modelId'] as int? {
    if (protocol == 'niimbot') {
      final model = NiimbotModel.fromId(modelId ?? -1);
      if (name.trim().isEmpty ||
          name.length > 80 ||
          !RegExp(r'^ble:([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(host) ||
          port != 0 ||
          widthDots < 64 ||
          widthDots > model.width ||
          widthDots % 8 != 0 ||
          heightDots < 64 ||
          heightDots > 2400) {
        throw const FormatException('Invalid NIIMBOT configuration');
      }
      return;
    }
    final ip = InternetAddress.tryParse(host);
    final bytes = ip?.rawAddress;
    if (name.trim().isEmpty ||
        name.length > 80 ||
        !['escpos', 'zpl'].contains(protocol) ||
        ip?.type != InternetAddressType.IPv4 ||
        bytes == null ||
        !(bytes[0] == 10 ||
            (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168)) ||
        bytes[3] == 0 ||
        bytes[3] == 255 ||
        port < 1 ||
        port > 65535 ||
        widthDots < 320 ||
        widthDots > 832 ||
        heightDots < 480 ||
        heightDots > 2400) {
      throw const FormatException('Invalid LAN printer configuration');
    }
  }
  final String name, protocol, host;
  final int port, widthDots, heightDots;
  final int? modelId;
  String get id => 'printer:$host:$port';
  Map<String, dynamic> toJson() => {
    'name': name,
    'protocol': protocol,
    'host': host,
    'port': port,
    'widthDots': widthDots,
    'heightDots': heightDots,
    if (modelId != null) 'modelId': modelId,
  };
}

class ProductionPrintJob {
  ProductionPrintJob(Map<String, dynamic> value)
    : payload = Map.unmodifiable(value) {
    final fields = {
      'version',
      'commandId',
      'operation',
      'printerId',
      'operationId',
      'product',
      'lot',
      'quantity',
      'unit',
      'producedAt',
      'expiresAt',
      'provisional',
      'reprintOf',
      'reprintReason',
      if ([2, 3].contains(value['version'])) 'factKind',
      if (value['version'] == 3) ...['productId', 'reportId'],
    };
    if (value.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(value.keys.toSet()).isNotEmpty ||
        ![1, 2, 3].contains(value['version']) ||
        value['version'] is! int ||
        (value['version'] == 2 &&
            (value['factKind'] != 'assigned_work' ||
                value['operation'] != 'productionWorkTicket' ||
                value['provisional'] != true)) ||
        (value['version'] == 3 &&
            (value['factKind'] != 'offline_output' ||
                value['operation'] != 'productionLabel' ||
                value['provisional'] != true ||
                value['expiresAt'] != null)) ||
        !productionPrintOperations.contains(value['operation']) ||
        value['provisional'] is! bool) {
      throw const FormatException('Invalid production print v1 payload');
    }
    for (final field in [
      'commandId',
      'printerId',
      'operationId',
      'product',
      'lot',
      'unit',
    ]) {
      text(
        field,
        field == 'product'
            ? 80
            : field == 'unit'
            ? 12
            : 100,
      );
    }
    if (value['version'] == 3) {
      text('productId', 100);
      text('reportId', 100);
      final uuid = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      );
      if (!uuid.hasMatch(value['reportId'] as String) ||
          !uuid.hasMatch(value['commandId'] as String) ||
          value['lot'] != 'LOCAL:${value['reportId']}') {
        throw const FormatException(
          'Provisional label requires an immutable local report identity',
        );
      }
    }
    final quantity = value['quantity'];
    if (quantity is! String ||
        quantity.length > 24 ||
        !RegExp(r'^\d{1,12}(\.\d{1,6})?$').hasMatch(quantity) ||
        !RegExp('[1-9]').hasMatch(quantity)) {
      throw const FormatException('Invalid print quantity');
    }
    for (final field in ['producedAt', 'expiresAt']) {
      if (field == 'expiresAt' && value[field] == null) continue;
      final timestamp = value[field];
      if (timestamp is! String ||
          timestamp.length > 30 ||
          !timestamp.endsWith('Z') ||
          DateTime.tryParse(timestamp) == null) {
        throw const FormatException('Invalid print timestamp');
      }
    }
    if ((value['reprintOf'] == null) != (value['reprintReason'] == null)) {
      throw const FormatException(
        'Reprint requires original command and reason',
      );
    }
    if (value['reprintOf'] != null) {
      text('reprintOf', 100);
      text('reprintReason', 100);
      if (value['reprintOf'] == value['commandId']) {
        throw const FormatException('Reprint requires a new command ID');
      }
    }
  }
  final Map<String, dynamic> payload;
  String text(String field, int max) {
    final value = payload[field];
    // Fixed templates only. Romanian letters are transliterated at rendering;
    // controls and ZPL metacharacters (including hex escapes) remain forbidden.
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > max ||
        !RegExp(r'^[\x20-\x7eĂăÂâÎîȘșȚțŞşŢţ]+$').hasMatch(value) ||
        RegExp(r'[\^~\\]').hasMatch(value)) {
      throw FormatException(
        'Câmpul $field depășește limita sau conține caractere neacceptate. Imprimanta acceptă text ASCII și românesc transliterat.',
      );
    }
    return value;
  }

  String get id => payload['commandId'] as String;
  String get operation => payload['operation'] as String;
  List<int> render(PrinterConfig config) {
    if (payload['printerId'] != config.id ||
        (operation == 'productionWorkTicket' && config.protocol != 'escpos') ||
        (operation == 'productionLabel' &&
            !['zpl', 'niimbot'].contains(config.protocol))) {
      throw const FormatException('Printer or protocol does not match intent');
    }
    final assignedWork = payload['version'] == 2;
    final offlineOutput = payload['version'] == 3;
    final lines = <String>[
      operation == 'productionPrintDiagnostic'
          ? 'DIAGNOSTIC - NON FISCAL'
          : 'PRODUCTION - NON FISCAL',
      if (assignedWork) 'ASSIGNED WORK - PLANNED OUTPUT',
      if (payload['provisional'] == true) 'PROVISIONAL OFFLINE - NOT CONFIRMED',
      if (offlineOutput) 'NOT ERP ACCEPTED - LOCAL OUTPUT',
      if (payload['reprintOf'] != null) 'REPRINT: ${payload['reprintOf']}',
      'Product: ${payload['product']}',
      '${assignedWork
          ? 'Reserved input lot'
          : offlineOutput
          ? 'Local lot'
          : 'Lot'}: ${payload['lot']}',
      '${assignedWork ? 'Planned qty' : 'Qty'}: ${payload['quantity']} ${payload['unit']}',
      '${assignedWork ? 'Started' : 'Produced'}: ${payload['producedAt']}',
      if (!assignedWork) 'Expires: ${payload['expiresAt'] ?? '-'}',
      if (offlineOutput) 'Report: ${payload['reportId']}',
      'Operation: ${payload['operationId']}',
      'Command: $id',
      if (payload['reprintReason'] != null)
        'Reason: ${payload['reprintReason']}',
    ];
    final columns = config.protocol == 'niimbot'
        ? (config.widthDots - 8) ~/ 8
        : config.widthDots ~/ 12;
    final wrapped = <String>[];
    for (final original in lines) {
      const romanian = {
        'Ă': 'A',
        'ă': 'a',
        'Â': 'A',
        'â': 'a',
        'Î': 'I',
        'î': 'i',
        'Ș': 'S',
        'ș': 's',
        'Ț': 'T',
        'ț': 't',
        'Ş': 'S',
        'ş': 's',
        'Ţ': 'T',
        'ţ': 't',
      };
      final line = original
          .split('')
          .map((character) => romanian[character] ?? character)
          .join();
      for (var start = 0; start < line.length; start += columns) {
        wrapped.add(
          line.substring(start, (start + columns).clamp(0, line.length)),
        );
      }
    }
    if (config.protocol == 'niimbot') return utf8.encode(wrapped.join('\n'));
    if (config.protocol == 'escpos') {
      return [0x1b, 0x40, ...ascii.encode('${wrapped.join('\n')}\n\n\n')];
    }
    if (wrapped.length * 26 + 24 > config.heightDots) {
      throw const FormatException('Label too small for complete content');
    }
    return ascii.encode(
      '^XA^PW${config.widthDots}^LL${config.heightDots}'
      '${[for (var i = 0; i < wrapped.length; i++) '^FO12,${12 + i * 26}^A0N,22,12^FD${wrapped[i]}^FS'].join()}'
      '^XZ',
    );
  }
}

typedef PrinterSend = Future<void> Function(PrinterConfig, List<int>);

Future<void> sendPrinterBytes(PrinterConfig config, List<int> bytes) async {
  if (config.protocol == 'niimbot') {
    final raster = await niimbotRaster(config, utf8.decode(bytes));
    await sendNiimbot(
      config.host.substring(4),
      config.modelId!,
      config.widthDots,
      config.heightDots,
      raster,
    );
    return;
  }
  final socket = await Socket.connect(
    config.host,
    config.port,
    timeout: const Duration(seconds: 5),
  );
  final subscription = socket.listen((_) {}, onError: (Object _) {});
  try {
    socket.add(bytes);
    await socket.flush().timeout(const Duration(seconds: 5));
  } finally {
    socket.destroy();
    await subscription.cancel();
  }
}

/// Same fixed production template as LAN; never truncate traceability fields.
Future<List<int>> niimbotRaster(PrinterConfig config, String text) async {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(
        color: Color(0xff000000),
        fontSize: 14,
        height: 1.15,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: config.widthDots - 8);
  if (painter.height + 8 > config.heightDots) {
    painter.dispose();
    throw const FormatException(
      'Eticheta este prea mică pentru conținutul complet. Mărește dimensiunea etichetei.',
    );
  }
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xffffffff), BlendMode.src);
  painter.paint(canvas, const Offset(4, 4));
  final picture = recorder.endRecording();
  final image = await picture.toImage(config.widthDots, config.heightDots);
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = List<int>.filled(config.widthDots ~/ 8 * config.heightDots, 0);
  for (var y = 0; y < config.heightDots; y++) {
    for (var x = 0; x < config.widthDots; x++) {
      final i = (y * config.widthDots + x) * 4;
      if (rgba!.getUint8(i) < 128) {
        result[y * (config.widthDots ~/ 8) + x ~/ 8] |= 0x80 >> (x % 8);
      }
    }
  }
  painter.dispose();
  image.dispose();
  picture.dispose();
  return result;
}

/// Shared executor and journal are supplied by LocalBridge; no second queue.
class ProductionPrinter {
  ProductionPrinter({
    required this.executor,
    required this.journal,
    this.send = sendPrinterBytes,
  });
  final HardwareCommandExecutor executor;
  final CommandJournal journal;
  final PrinterSend send;

  Future<Map<String, Object?>> execute(
    PrinterConfig config,
    ProductionPrintJob job, {
    required Future<void> Function() authorize,
    bool recover = false,
    Map<String, dynamic> audit = const {},
  }) {
    final bytes = job.render(config);
    final journalPayload = <String, dynamic>{...job.payload, ...audit};
    return executor.execute(
      equipment: config.id,
      id: job.id,
      operation: job.operation,
      payload: journalPayload,
      dispatch: () async {
        await authorize();
        final previous = await journal.lookup(
          id: job.id,
          deviceId: config.id,
          operation: job.operation,
          payload: journalPayload,
        );
        HardwareResult? result = previous;
        if (result == null && !recover) {
          if (job.payload['reprintOf'] != null &&
              !await journal.hasProductionPrint(
                job.payload['reprintOf'] as String,
                config.id,
                job.operation,
              )) {
            throw const FormatException('Original print command is missing');
          }
          result = await journal.execute(
            id: job.id,
            deviceId: config.id,
            operation: job.operation,
            payload: journalPayload,
            dispatch: () async {
              await send(config, bytes);
              return const HardwareResult(
                CommandOutcome.unknown,
                reference: 'sent_unconfirmed',
                message:
                    'Trimis; imprimarea fizică nu este confirmată. Nu retrimite automat.',
              );
            },
          );
        }
        return {
          'outcome': result?.outcome.name ?? 'unknown',
          'delivery': result?.reference == 'sent_unconfirmed'
              ? 'sent_unconfirmed'
              : 'unknown',
          'commandId': job.id,
          'operation': job.operation,
          'printerId': config.id,
          'journalFound': result != null,
          'message':
              result?.message ??
              'Fără rezultat în jurnal; comanda nu a fost retrimisă.',
        };
      },
    );
  }
}
