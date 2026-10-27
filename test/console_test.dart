import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/console/console_contract.dart';
import 'package:chimera_companion/console/console_service.dart';
import 'package:chimera_companion/console/console_transport.dart';
import 'package:chimera_companion/console/ulanzi_adapter.dart';
import 'package:chimera_companion/console/ulanzi_protocol.dart';
import 'package:chimera_companion/security/offline_session.dart';
import 'signed_http_authorization_test.dart' show SigningFixture;

class UsbFixture implements ConsoleTransport {
  final input = StreamController<Uint8List>.broadcast();
  final writes = <List<Uint8List>>[];
  bool ready = true;
  @override
  Stream<Uint8List> get reports => input.stream;
  @override
  Future<List<Map<String, dynamic>>> devices() async => [];
  @override
  Future<void> open(String id) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> write(List<Uint8List> packets) async {
    writes.add(packets);
    if (UlanziProtocol.command(packets.first) == 3) {
      input.add(
        Uint8List.fromList([
          0x7c,
          0x7c,
          3,
          3,
          0,
          0,
          0,
          0,
          ...utf8.encode(jsonEncode({'error': ready ? 0 : 1})),
        ]),
      );
    }
  }

  void button(int index, bool down) => input.add(
    Uint8List.fromList([
      0x7c,
      0x7c,
      1,
      1,
      4,
      0,
      0,
      0,
      0,
      index,
      1,
      down ? 1 : 0,
    ]),
  );
}

class AdapterFixture implements ConsoleAdapter {
  final input = StreamController<int>.broadcast();
  final screens = <ConsoleFrame>[];
  @override
  Stream<int> get presses => input.stream;
  @override
  Map<String, Object?> get diagnostics => {'uploads': screens.length};
  @override
  Future<void> connect(String id) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> display(ConsoleFrame frame) async {
    screens.add(frame);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'USB framing preserves multi-packet ZIP payload and endian contract',
    () {
      for (final size in [0, 1016, 1017, 2040, 12000]) {
        final input = List.generate(size, (i) => i % 256),
            packets = UlanziProtocol.packets(1, input);
        expect(packets.every((p) => p.length == 1024), isTrue);
        expect(
          ByteData.sublistView(packets.first).getUint32(4, Endian.little),
          size,
        );
        expect(
          [
            ...packets.first.skip(8),
            ...packets.skip(1).expand((p) => p),
          ].take(size),
          input,
        );
      }
      expect(() => UlanziProtocol.packets(0xff, []), throwsArgumentError);
      final zip = ZipDecoder().decodeBytes(
        UlanziProtocol.screen({
          0: Uint8List.fromList([1, 2]),
        }),
      );
      final manifest = jsonDecode(
        utf8.decode(zip.findFile('manifest.json')!.content),
      );
      final imagePath = manifest['0_0']['ViewParam'][0]['Icon'] as String;
      expect(imagePath, matches(RegExp(r'^icons/[a-f0-9]{64}\.png$')));
      expect(zip.findFile(imagePath)!.content, [1, 2]);
      expect(manifest['3_2']['SmallViewMode'], 1);
    },
  );
  test(
    'new screen pixels never reuse an old firmware image path; identical pixels deduplicate',
    () {
      final oldImage = Uint8List.fromList([1, 2, 3]),
          newImage = Uint8List.fromList([4, 5, 6]);
      Archive upload(Uint8List icon) =>
          ZipDecoder().decodeBytes(UlanziProtocol.screen({0: icon, 1: icon}));
      String path(Archive zip, String slot) =>
          jsonDecode(
                utf8.decode(zip.findFile('manifest.json')!.content),
              )[slot]['ViewParam'][0]['Icon']
              as String;
      final before = upload(oldImage), after = upload(newImage);
      expect(path(before, '0_0'), isNot(path(after, '0_0')));
      expect(path(after, '0_0'), path(after, '1_0'));
      expect(after.files.where((f) => f.name.endsWith('.png')), hasLength(1));
      final decoderCache = <String, List<int>>{};
      for (final zip in [before, after]) {
        for (final f in zip.files.where((f) => f.name.endsWith('.png'))) {
          decoderCache.putIfAbsent(f.name, () => f.content);
        }
      }
      expect(decoderCache[path(after, '0_0')], newImage);
    },
  );
  test(
    'malformed or executable console contracts and duplicate actions are rejected',
    () {
      final base = {
        'version': 1,
        'revision': 1,
        'title': 'Lucrare',
        'keys': [
          {'id': 'start', 'label': 'Începe', 'icon': 'start', 'enabled': true},
        ],
      };
      expect(ConsoleFrame.parse(base).keys.single.id, 'start');
      expect(
        () => ConsoleFrame.parse({
          ...base,
          'keys': List.filled(14, (base['keys'] as List).single),
        }),
        throwsFormatException,
      );
      expect(
        () => ConsoleFrame.parse({
          ...base,
          'keys': [
            {
              'id': 'start',
              'label': 'Începe',
              'icon': 'rawEcr',
              'enabled': true,
            },
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => ConsoleFrame.parse({...base, 'revision': 0}),
        throwsFormatException,
      );
    },
  );
  test(
    'Ulanzi waits for firmware, suppresses held keys and avoids identical screen uploads',
    () async {
      final usb = UsbFixture();
      final device = UlanziAdapter(
        usb,
        render: (_) async => Uint8List.fromList([1, 2, 3]),
      );
      final presses = <int>[], sub = device.presses.listen(presses.add);
      await device.connect('fixture');
      const screen = ConsoleFrame(1, 'Work', [
        ConsoleKey('done', 'Gata', 'done', true),
      ]);
      await device.display(screen);
      await device.display(screen);
      expect(
        usb.writes.where((p) => UlanziProtocol.command(p.first) == 1).length,
        1,
      );
      usb.button(0, true);
      usb.button(0, true);
      usb.button(14, true);
      await Future<void>.delayed(Duration.zero);
      expect(presses, [0]);
      await device.close();
      await sub.cancel();
      await usb.input.close();
    },
  );
  test('unready firmware rejects initialization', () async {
    final usb = UsbFixture()..ready = false;
    final device = UlanziAdapter(usb);
    await expectLater(device.connect('fixture'), throwsFormatException);
    await usb.input.close();
  });
  test(
    'one consumer and one press per fresh view; release and stale revisions cannot execute',
    () async {
      final adapter = AdapterFixture();
      final console = ConsoleService(adapter: adapter);
      await console.connect('fixture');
      final events = <Map<String, Object>>[],
          sub = console.events.listen(events.add);
      console.acquire();
      expect(console.acquire, throwsStateError);
      await console.show(
        const ConsoleFrame(1, 'Work', [
          ConsoleKey('done', 'Gata', 'done', true),
        ]),
      );
      adapter.input.add(0);
      adapter.input.add(0);
      await Future<void>.delayed(Duration.zero);
      expect(events.length, 1);
      expect(events.single['revision'], 1);
      await expectLater(
        console.show(const ConsoleFrame(1, 'Old', [])),
        throwsStateError,
      );
      await console.release();
      adapter.input.add(0);
      await Future<void>.delayed(Duration.zero);
      expect(events.length, 1);
      await sub.cancel();
      await console.close();
      await adapter.input.close();
    },
  );
  test(
    'console grants bind device, origin, Companion and short expiry without granting printing',
    () async {
      final dir = await Directory.systemTemp.createTemp('console-auth-');
      final authority = SigningFixture(41),
          companion = SigningFixture(42),
          device = SigningFixture(43);
      final now = DateTime.now(), seconds = now.millisecondsSinceEpoch ~/ 1000;
      final session = OfflineSession(
        file: File('${dir.path}/session'),
        org: 'org',
        location: 'lab',
        companion: 'companion',
        identity: companion,
        now: () => now,
      );
      try {
        await session.restore();
        await session.updateTrust({
          'signing_keys': [
            {...authority.jwk, 'kid': 'fixture-authority'},
          ],
          'peers': [],
        });
        final claims = {
          'iss': 'chimera-companion',
          'kind': 'kds-console',
          'org': 'org',
          'location': 'lab',
          'aud': 'companion',
          'companion': 'companion',
          'sub': 'station',
          'pos': 'station',
          'version': 1,
          'operations': ['console'],
          'cnf': {'jwk': device.jwk},
          'peer': {'jwk': companion.jwk},
          'origin': 'https://kds.example',
          'iat': seconds,
          'nbf': seconds,
          'exp': seconds + 60,
        };
        final verified = session.verifyConsole(
          authority.token(claims),
          'https://kds.example',
        );
        expect(
          session.verifyConsoleProof(
            verified,
            'nonce',
            device.signature('nonce'),
          ),
          isTrue,
        );
        expect(
          session.verifyConsoleProof(
            verified,
            'nonce',
            companion.signature('nonce'),
          ),
          isFalse,
        );
        for (final overrides in [
          {'org': 'other'},
          {'location': 'other'},
          {'exp': seconds - 1},
          {'exp': seconds + 61},
          {
            'operations': ['print'],
          },
          {
            'peer': {'jwk': device.jwk},
          },
        ]) {
          expect(
            () => session.verifyConsole(
              authority.token({...claims, ...overrides}),
              'https://kds.example',
            ),
            throwsFormatException,
          );
        }
        expect(
          () => session.verifyConsole(
            authority.token(claims),
            'https://other.example',
          ),
          throwsFormatException,
        );
        await session.revokeLocally('station');
        expect(
          () => session.verifyConsole(
            authority.token(claims),
            'https://kds.example',
          ),
          throwsFormatException,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
