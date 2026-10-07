import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:math';
Future<void> Function(String,String)? reportCompanionError;
String _eventId() {
  final random=Random.secure();
  final bytes=List.generate(16,(_)=>random.nextInt(256));
  bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;
  final hex=bytes.map((b)=>b.toRadixString(16).padLeft(2,'0')).join();
  return '${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}';
}

/// Durable, serialized diagnostic delivery. Never stores payloads or credentials.
class DiagnosticOutbox {
  DiagnosticOutbox(this.storage, this.post,{required String scope}):_key='companion_diagnostic_outbox_v1:$scope';
  final FlutterSecureStorage storage;
  final Future<Map<String,dynamic>> Function(String,Map<String,Object?>) post;
  Future<void> _tail = Future.value();
  final String _key;
  Future<int> overflow() async => int.tryParse(await storage.read(key:'${_key}_overflow')??'0')??0;
  Future<void> _serial(Future<void> Function() action) {
    final next=_tail.catchError((_){ }).then((_)=>action());
    _tail=next;
    return next;
  }
  Future<List<dynamic>> _read() async => jsonDecode(await storage.read(key:_key)??'[]') as List<dynamic>;
  Future<void> add(String code,String detail) => _serial(() async {
    final items=await _read();
    if(items.length>=1000){await storage.write(key:'${_key}_overflow',value:'${int.parse(await storage.read(key:'${_key}_overflow')??'0')+1}');return;}
    items.add({'id':_eventId(),'code':code,'detail':detail.length>1200?detail.substring(0,1200):detail,'at':DateTime.now().toUtc().toIso8601String()});
    await storage.write(key:_key,value:jsonEncode(items));
  });
  Future<void> flush() => _serial(() async {
    final items=await _read();
    if(items.isEmpty)return;
    final batch=items.take(50).toList();
    final response=await post('/api/devices/companion/management/events',{'events':batch});
    if(response['accepted']!=true)throw StateError('Diagnostic acknowledgment missing');
    await storage.write(key:_key,value:jsonEncode(items.skip(batch.length).toList()));
  });
}
