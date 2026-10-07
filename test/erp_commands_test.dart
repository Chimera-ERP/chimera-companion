import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/erp_commands.dart';

void main() {
  test('response loss recovers result without a second dispatch', () async {
    var dispatched = 0, acknowledgements = 0, polls = 0;
    final client = ErpCommands(
      post: (path, body) async {
        if (path.endsWith('/pull')) {
          return {
            'commands': [
              {
                'id': 'command',
                'operation': 'xReport',
                'payload': {},
                'ticket': polls++ == 0 ? 'first' : 'recover',
              },
            ],
          };
        }
        acknowledgements++;
        if (acknowledgements == 1) throw Exception('Lost acknowledgement');
        expect(jsonDecode(body['message'] as String)['outcome'], 'succeeded');
        return {'accepted': true};
      },
      verify: (ticket, payload) => {
        'commandId': 'command',
        'operations': ['xReport'],
        'dispatch': ticket == 'first',
      },
      dispatch: (_, _) async {
        dispatched++;
        return {'outcome': 'succeeded', 'message': 'Cached report'};
      },
      recover: (_, _) async => {
        'outcome': 'succeeded',
        'message': 'Cached report',
      },
      sign: (_) async => 'signature',
    );
    await expectLater(client.poll(), throwsException);
    await client.poll();
    expect(dispatched, 1);
    expect(acknowledgements, 2);
  });
  test('lost claim response never authorizes blind redispatch', () async {
    var dispatched = 0;
    final client = ErpCommands(
      post: (path, body) async => path.endsWith('/pull')
          ? {
              'commands': [
                {
                  'id': 'command',
                  'operation': 'zReport',
                  'payload': {},
                  'ticket': 'recovery',
                },
              ],
            }
          : {'accepted': true},
      verify: (_, _) => {
        'commandId': 'command',
        'operations': ['zReport'],
        'dispatch': false,
      },
      dispatch: (_, _) async {
        dispatched++;
        return {};
      },
      recover: (_, _) async => {'outcome': 'unknown', 'message': 'Not resent'},
      sign: (_) async => 'signature',
    );
    await client.poll();
    expect(dispatched, 0);
  });
  test('canonical payload hash ignores JSON key order', () {
    expect(
      hardwarePayloadHash({
        'lines': ['test'],
        'confirm': true,
      }),
      hardwarePayloadHash({
        'confirm': true,
        'lines': ['test'],
      }),
    );
  });
}
