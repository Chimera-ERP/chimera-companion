import 'package:flutter_test/flutter_test.dart';
import 'package:chimera_companion/security/daily_z.dart';
Map<String,dynamic> policy({String deadline='02:00'})=>{'z_enabled':true,'z_block_sales':true,'time_zone':'Europe/Bucharest','z_deadline':deadline,'z_warning_minutes':30};
void main() {
  test('disabled policy and a verified empty register never require an empty Z',(){
    final p=DailyZPolicy(),now=DateTime.utc(2026,10,4);
    expect(p.evaluate(null,now,hardwareNonZero:true)['blocked'],false);
    expect(p.evaluate(policy(),now,hardwareNonZero:false)['requiresZ'],false);
  });
  test('overnight deadline warns before 02:00 local and blocks afterward',(){
    final p=DailyZPolicy(),start=DateTime.utc(2026,10,3,17);
    p.receiptObserved(start,start);
    expect(p.evaluate(policy(),DateTime.utc(2026,10,3,22,40),hardwareNonZero:true)['warning'],true);
    expect(p.evaluate(policy(),DateTime.utc(2026,10,3,23),hardwareNonZero:true)['blocked'],true);
  });
  test('verified external Z clears previous activity; a later receipt starts another day',(){
    final p=DailyZPolicy(),start=DateTime.utc(2026,10,3,17);
    p.receiptObserved(start,start);
    p.evaluate(policy(),DateTime.utc(2026,10,3,23),hardwareNonZero:false);
    final next=DateTime.utc(2026,10,4,5);p.receiptObserved(next,next);
    expect(p.evaluate(policy(),next,hardwareNonZero:true)['deadline'],'2026-10-04T23:00:00.000Z');
  });
  test('DST calendar deadlines have 23/25-hour intervals, not fixed UTC offsets',(){
    final spring=DailyZPolicy(),s=DateTime.utc(2026,3,28,2);
    spring.receiptObserved(s,s);
    expect(spring.evaluate(policy(deadline:'04:00'),s,hardwareNonZero:true)['deadline'],'2026-03-29T01:00:00.000Z');
    final autumn=DailyZPolicy(),a=DateTime.utc(2026,10,24,1);
    autumn.receiptObserved(a,a);
    expect(autumn.evaluate(policy(deadline:'04:00'),a,hardwareNonZero:true)['deadline'],'2026-10-25T02:00:00.000Z');
  });
  test('restart retains overdue activity and detects clock rollback',(){
    final p=DailyZPolicy(),start=DateTime.utc(2026,10,3,17);p.receiptObserved(start,start);
    final restored=DailyZPolicy(p.toJson());
    expect(restored.evaluate(policy(),DateTime.utc(2026,10,4),hardwareNonZero:true)['blocked'],true);
    expect(()=>restored.evaluate(policy(),start,hardwareNonZero:true),throwsFormatException);
  });
  test('untracked or unreadable fiscal activity does not bypass blocking',(){
    for(final nonZero in [true,null]) {
      expect(DailyZPolicy().evaluate(policy(),DateTime.utc(2026,10,4),hardwareNonZero:nonZero)['blocked'],true);
    }
  });
}
