import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/hardware/command_journal.dart';
import 'package:chimera_companion/hardware/contracts.dart';
import 'package:chimera_companion/hardware/runtime.dart';
import 'package:chimera_companion/hardware/viva_adapter.dart';
import 'package:chimera_companion/hardware/tremol_adapter.dart';
import 'package:chimera_companion/hardware/tremol_protocol.dart';
import 'adapters_test.dart' as fixtures;
import 'viva_test.dart' as viva;

class JournalPeer extends fixtures.TremolPeer {
  int counter=1;
  bool loseCounterAfterClose=false;
  bool wrongMarker=false;
  bool corruptStream=false;
  String serial='TEST0000001';
  final markers=<String>[];
  @override
  Future<List<int>> exchange(List<int> request,int? Function(List<int>) frameLength) async {
    if(request.length==1)return super.exchange(request,frameLength);
    final command=request[3],sequence=request[2];
    if(command==0x60)return TremolProtocol.encode(sequence,command,ascii.encode(serial));
    if(command==0x71){
      if(loseCounterAfterClose&&counter>1)throw StateError('Lost identity response');
      return TremolProtocol.encode(sequence,command,ascii.encode('0001;${counter.toString().padLeft(7,'0')}'));
    }
    if(command==0x37)markers.add(ascii.decode(request.sublist(4,request.length-3)));
    if(command==0x38)counter++;
    if(command==0x7c){
      commands.add(command);
      expect(ascii.decode(request.sublist(4,request.length-3)),'J0;N;000002;000002');
      final body=[sequence,0x30,0x30];final sum=body.fold<int>(0,(a,b)=>a^b);
      final bytes=[6,...body,0x30+(sum>>4),0x30+(sum&15),10,
        for(final marker in markers)...TremolProtocol.encode(sequence,command,ascii.encode(wrongMarker?'WRONG':marker)),0x40];
      if(corruptStream)bytes[bytes.length-3]^=1;
      // Exercise the length parser with fragmented delivery too.
      for(var n=0;n<bytes.length;n++){expect(frameLength(bytes.sublist(0,n)),isNull);}
      expect(frameLength(bytes),bytes.length);
      return bytes;
    }
    return super.exchange(request,frameLength);
  }
}

void main(){
  late Directory dir;
  late CommandJournal journal;
  setUp(()async{dir=await Directory.systemTemp.createTemp('reconcile-');journal=CommandJournal(File('${dir.path}/journal'));});
  tearDown(()async{await dir.delete(recursive:true);});
  test('Viva lost response recovers with GET only and survives restart',()async{
    final peer=viva.VivaPeer([])..fail=true;
    final adapter=VivaAdapter(peer);
    final request=viva.payment();
    expect((await HardwareRuntime(journal).payment('terminal',adapter,request)).outcome,CommandOutcome.unknown);
    peer.fail=false;peer.responses.add(viva.response('SUCCESS'));
    final recovered=await HardwareRuntime(CommandJournal(journal.file)).payment('terminal',adapter,request,recoveryOnly:true);
    expect(recovered.outcome,CommandOutcome.succeeded);
    expect(peer.calls.map((call)=>call.$1),['POST','GET']);
    expect((await HardwareRuntime(CommandJournal(journal.file)).payment('terminal',adapter,request)).reference,'payment-confirmed');
    expect(peer.calls,hasLength(2));
  });
  test('missing payment journal never contacts terminal; mismatched amount never reconciles',()async{
    final peer=viva.VivaPeer([])..fail=true;final adapter=VivaAdapter(peer);
    expect((await HardwareRuntime(journal).payment('terminal',adapter,viva.payment(),recoveryOnly:true)).outcome,CommandOutcome.unknown);
    expect(peer.calls,isEmpty);
    await HardwareRuntime(journal).payment('terminal',adapter,viva.payment());
    await expectLater(HardwareRuntime(journal).payment('terminal',adapter,PaymentRequest(commandId:viva.session,amountMinor:1,currency:'RON'),recoveryOnly:true),throwsStateError);
    expect(peer.calls,hasLength(1));
  });
  test('unmatched or unavailable Viva session stays unknown without another POST',()async{
    final peer=viva.VivaPeer([])..fail=true;final adapter=VivaAdapter(peer);
    await HardwareRuntime(journal).payment('terminal',adapter,viva.payment());
    peer.fail=false;peer.responses.add(viva.response('SUCCESS',amount:1999));
    expect((await HardwareRuntime(journal).payment('terminal',adapter,viva.payment(),recoveryOnly:true)).outcome,CommandOutcome.unknown);
    peer.fail=true;
    expect((await HardwareRuntime(journal).payment('terminal',adapter,viva.payment(),recoveryOnly:true)).outcome,CommandOutcome.unknown);
    expect(peer.calls.map((call)=>call.$1),['POST','GET','GET']);
  });
  test('Tremol close checkpoint plus exact EJ marker recovers lost counter without print',()async{
    final peer=JournalPeer()..loseCounterAfterClose=true;
    Map<String,dynamic>? evidence;
    final adapter=TremolAdapter(fixtures.connection(),sessions:(_)async=>peer,checkpoint:(value)async{evidence=jsonDecode(jsonEncode(value));});
    expect((await adapter.printReceipt(fixtures.receipt())).outcome,CommandOutcome.unknown);
    expect(evidence?['closed'],true);
    expect(peer.markers,TremolAdapter.receiptMarkers('cmd'));
    final writes=peer.commands.length;
    peer.loseCounterAfterClose=false;
    final result=await adapter.reconcileReceipt('cmd',evidence);
    expect(result.outcome,CommandOutcome.succeeded);
    expect(result.reference,'0000002:0001');
    expect(peer.commands.skip(writes),[0x7c]);
    expect(peer.commands.where((c)=>c==0x30),hasLength(1));
  });
  test('Tremol does not infer emission from a counter, marker, or uncertain close alone',()async{
    final peer=JournalPeer();Map<String,dynamic>? evidence;
    final adapter=TremolAdapter(fixtures.connection(),sessions:(_)async=>peer,checkpoint:(value)async{evidence=jsonDecode(jsonEncode(value));});
    await adapter.printReceipt(fixtures.receipt());
    peer.wrongMarker=true;
    expect((await adapter.reconcileReceipt('cmd',evidence)).outcome,CommandOutcome.unknown);
    peer.wrongMarker=false;peer.corruptStream=true;
    expect((await adapter.reconcileReceipt('cmd',evidence)).outcome,CommandOutcome.unknown);
    peer.corruptStream=false;peer.serial='OTHER000001';
    expect((await adapter.reconcileReceipt('cmd',evidence)).outcome,CommandOutcome.unknown);
    expect((await adapter.reconcileReceipt('cmd',{...evidence!,'closed':false})).outcome,CommandOutcome.unknown);
    expect((await adapter.reconcileReceipt('another',evidence)).outcome,CommandOutcome.unknown);
    expect((await adapter.reconcileReceipt('cmd',null)).outcome,CommandOutcome.unknown);
    expect(peer.commands.where((c)=>c==0x30),hasLength(1));
  });
  test('checkpoint failure before receipt opening prevents all fiscal writes',()async{
    final peer=JournalPeer();
    final result=await TremolAdapter(fixtures.connection(),sessions:(_)async=>peer,checkpoint:(_)async=>throw StateError('disk')).printReceipt(fixtures.receipt());
    expect(result.outcome,CommandOutcome.rejected);
    expect(peer.commands,[0x20]);
  });
}
