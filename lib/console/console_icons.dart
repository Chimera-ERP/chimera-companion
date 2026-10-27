import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'console_contract.dart';

Future<Uint8List> renderConsoleKey(ConsoleKey key) async {
  const icons = {
    'previous': Icons.arrow_back,
    'next': Icons.arrow_forward,
    'open': Icons.open_in_full,
    'back': Icons.close,
    'start': Icons.play_arrow,
    'pause': Icons.pause,
    'resume': Icons.play_arrow,
    'done': Icons.done,
    'person': Icons.person_outline,
    'check': Icons.check_circle_outline,
    'refresh': Icons.refresh,
    'up': Icons.arrow_upward,
    'down': Icons.arrow_downward,
    'coffee': Icons.local_cafe_outlined,
    'cake': Icons.cake_outlined,
    'water': Icons.water_drop_outlined,
    'oven': Icons.microwave_outlined,
    'timer': Icons.timer_outlined,
    'box': Icons.inventory_2_outlined,
    'star': Icons.star_outline,
    'settings': Icons.settings_outlined,
  };
  final recorder = ui.PictureRecorder();
  // Flutter paints the same semantic icons as the UI; no remote image assets.
  final target = Canvas(recorder);
  target.drawColor(const Color(0xff000000), BlendMode.src);
  final glyph = icons[key.icon]!,
      color = key.enabled ? Colors.white : const Color(0xff656565);
  final painter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(glyph.codePoint),
      style: TextStyle(
        fontFamily: glyph.fontFamily,
        package: glyph.fontPackage,
        fontSize: 80,
        color: color,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  if (key.label.isNotEmpty) {
    painter.paint(target, Offset((196 - painter.width) / 2, 25));
  }
  painter.dispose();
  final label = TextPainter(
    text: TextSpan(
      text: key.label,
      style: TextStyle(fontSize: 22, color: color, fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: 180);
  label.paint(target, Offset((196 - label.width) / 2, 124));
  label.dispose();
  final picture = recorder.endRecording(),
      image = await picture.toImage(196, 196);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  picture.dispose();
  return bytes;
}
