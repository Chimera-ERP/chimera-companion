import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

/// Fiscal activity is observed from hardware; a UI checkbox never resets it.
/// State belongs to an ECR, not to a POS/operator or the calendar midnight.
class DailyZPolicy {
  DailyZPolicy([Map<String,dynamic>? saved]) {
    if(!_initialized){data.initializeTimeZones();_initialized=true;}
    firstActivity=_date(saved?['firstActivity']);
    highWater=_date(saved?['highWater']);
  }
  static bool _initialized=false;
  DateTime? firstActivity,highWater;
  static DateTime? _date(dynamic value)=>value==null?null:DateTime.parse(value as String).toUtc();
  void _clock(DateTime now) {
    now=now.toUtc();
    if(highWater!=null&&now.isBefore(highWater!))throw const FormatException('Clock rollback: fiscal state requires verification');
    highWater=now;
  }
  void receiptObserved(DateTime started,DateTime now) {
    _clock(now);
    if(started.isAfter(now))throw const FormatException('Future fiscal activity');
    firstActivity??=started.toUtc();
  }
  Map<String,dynamic> evaluate(Map<dynamic,dynamic>? policy,DateTime now,{required bool? hardwareNonZero}) {
    _clock(now);
    if(hardwareNonZero==false)firstActivity=null;
    final enabled=policy?['z_enabled']==true;
    if(!enabled)return {'enabled':false,'warning':false,'blocked':false,'requiresZ':false};
    final block=policy?['z_block_sales']==true;
    if(hardwareNonZero==null||(hardwareNonZero==true&&firstActivity==null)) {
      return {'enabled':true,'warning':true,'blocked':block,'requiresZ':true,'uncertain':true,'message':'Starea zilei fiscale trebuie verificată. Emite Z când casa confirmă activitatea.'};
    }
    if(hardwareNonZero==false)return {'enabled':true,'warning':false,'blocked':false,'requiresZ':false};
    final match=RegExp(r'^(\d{2}):(\d{2})(?::00)?$').firstMatch(policy?['z_deadline'] as String? ?? '');
    if(match==null)throw const FormatException('Invalid daily Z deadline');
    final hour=int.parse(match[1]!),minute=int.parse(match[2]!);
    if(hour>23||minute>59)throw const FormatException('Invalid daily Z deadline');
    final location=tz.getLocation(policy?['time_zone'] as String? ?? '');
    final start=tz.TZDateTime.from(firstActivity!,location);
    var deadline=tz.TZDateTime(location,start.year,start.month,start.day,hour,minute);
    // Calendar arithmetic, never +24h: an overnight day can have 23/25 hours.
    if(!deadline.isAfter(start))deadline=tz.TZDateTime(location,start.year,start.month,start.day+1,hour,minute);
    final warning=policy?['z_warning_minutes'];
    if(warning is! int||warning<0||warning>240)throw const FormatException('Invalid Z warning interval');
    final overdue=!now.isBefore(deadline);
    return {'enabled':true,'deadline':deadline.toUtc().toIso8601String(),'warning':!now.isBefore(deadline.subtract(Duration(minutes:warning))),
      'blocked':block&&overdue,'requiresZ':overdue,'uncertain':false};
  }
  Map<String,dynamic> toJson()=>{'firstActivity':firstActivity?.toIso8601String(),'highWater':highWater?.toIso8601String()};
}
