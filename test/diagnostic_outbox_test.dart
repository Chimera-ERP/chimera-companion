import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chimera_companion/diagnostic_outbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage=FlutterSecureStorage();
  setUp(()=>FlutterSecureStorage.setMockInitialValues({}));
  test('lost acknowledgement preserves exact event identity across restart', () async {
    final sent=<Map<String,Object?>>[];
    var fail=true;
    Future<Map<String,dynamic>> post(String path,Map<String,Object?> body) async {
      sent.add(jsonDecode(jsonEncode(body)) as Map<String,Object?>);
      if(fail)throw StateError('response lost');
      return {'accepted':true};
    }
    final first=DiagnosticOutbox(storage,post,scope:'org:phone');
    await first.add('authorization_rejected','Operator authentication required');
    await expectLater(first.flush(),throwsStateError);
    fail=false;
    await DiagnosticOutbox(storage,post,scope:'org:phone').flush();
    expect(sent[1],sent[0]);
    await first.flush();expect(sent.length,2);
  });
  test('new enrollment never sends previous organization diagnostics', () async {
    var posts=0;
    Future<Map<String,dynamic>> post(String path,Map<String,Object?> body) async {posts++;return {'accepted':true};}
    await DiagnosticOutbox(storage,post,scope:'first:phone').add('http_rejected','HTTP 403');
    await DiagnosticOutbox(storage,post,scope:'second:phone').flush();
    expect(posts,0);
    await DiagnosticOutbox(storage,post,scope:'first:phone').flush();
    expect(posts,1);
  });
}
