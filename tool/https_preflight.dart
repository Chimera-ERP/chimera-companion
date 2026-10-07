import 'dart:io';
import 'package:chimera_companion/local_server.dart';
import 'package:chimera_companion/local_tls.dart';

/// Transport-only probe: deliberately unable to execute hardware commands.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/https_preflight.dart <private-tls-directory>',
    );
    exitCode = 64;
    return;
  }
  final tls = await LocalTls.load(Directory(arguments.single));
  final server = CompanionServer(
    verify: (_) async =>
        throw StateError('Preflight does not authorize commands'),
    run: (_, _, _) async => throw StateError('Hardware disabled in preflight'),
  );
  await server.start(securityContext: tls.context);
  stdout.writeln('HTTPS preflight: ${tls.origin.origin}/health');
  stdout.writeln('No hardware operations enabled. Stop with Ctrl+C.');
}
