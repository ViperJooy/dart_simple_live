import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  CoreLog.requestLogType = RequestLogType.short;
  
  test('check if huya lines change between requests', () async {
    final site = HuyaSite();
    
    final details = [];
    for (var i = 0; i < 3; i++) {
      final detail = await site.getRoomDetail(roomId: '31420211');
      details.add(detail);
      await Future.delayed(Duration(seconds: 1));
    }
    
    for (var i = 0; i < details.length; i++) {
      final data = details[i].data as HuyaUrlDataModel;
      print('第 ${i + 1} 次: ${data.lines.length} 条线路');
      for (var j = 0; j < data.lines.length; j++) {
        print('  $j: ${data.lines[j].cdnType} ${data.lines[j].line}');
      }
    }
    
    final data0 = details[0].data as HuyaUrlDataModel;
    final data1 = details[1].data as HuyaUrlDataModel;
    final data2 = details[2].data as HuyaUrlDataModel;
    
    print('\\n线路是否相同:');
    print('0 vs 1: ${data0.lines.map((l) => l.line).join(',') == data1.lines.map((l) => l.line).join(',')}');
    print('1 vs 2: ${data1.lines.map((l) => l.line).join(',') == data2.lines.map((l) => l.line).join(',')}');
  }, timeout: Timeout(Duration(seconds: 30)));
}
