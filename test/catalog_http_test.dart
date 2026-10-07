import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/tremol_catalog.dart';

void main() {
  test(
    'discovery reads only getcmds and does not send device commands',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        request.response.write('[{"Name":"ReadStatus","Doc":"<Command />"}]');
        await request.response.close();
      });
      final catalog = await TremolCatalogClient(
        Uri.parse('http://127.0.0.1:${server.port}'),
      ).discover();
      expect(catalog.single.name, 'ReadStatus');
      expect(requests, ['GET /getcmds']);
    },
  );
  test(
    'redirects are rejected rather than following an arbitrary command URL',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var count = 0;
      server.listen((request) async {
        count++;
        request.response.statusCode = 302;
        request.response.headers.set('location', '/PaperFeed()');
        await request.response.close();
      });
      await expectLater(
        TremolCatalogClient(
          Uri.parse('http://127.0.0.1:${server.port}'),
        ).discover(),
        throwsA(isA<HttpException>()),
      );
      expect(count, 1);
    },
  );
}
