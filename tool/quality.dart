import 'dart:io';

Future<void> main(List<String> args) async {
  final process = await Process.start('node', ['.quality/runtime.mjs', ...args], mode: ProcessStartMode.inheritStdio);
  exit(await process.exitCode);
}
