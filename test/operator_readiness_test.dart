import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/fiscal_device.dart';
import 'adapters_test.dart' as fixtures;

void main() {
  for (final item in [
    {'active': <String,dynamic>{}, 'message': 'nu are un operator'},
    {'active': <String,dynamic>{'operatorId':'other'}, 'message':'alt operator'},
    {'active': <String,dynamic>{'operatorId':'admin','closed':true}, 'message':'este închisă'},
    {'active': <String,dynamic>{'operatorId':'admin','closingId':'exit'}, 'message':'neconfirmat'},
  ]) {
    test('operator refusal identifies ${item['message']} without contacting hardware', () async {
      final device = FiscalDevice(fixtures.connection());
      final ready = await device.operatorReady({'operatorId':'admin','operatorName':'admin'},
          (key) async => key.startsWith('operator_active_') ? item['active'] as Map<String,dynamic> : {});
      expect(ready, isFalse);
      expect(device.operatorReadinessMessage, contains(item['message'] as String));
    });
  }
}
