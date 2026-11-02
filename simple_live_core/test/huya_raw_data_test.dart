import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  test('check raw room data', () async {
    final site = HuyaSite();
    final detail = await site.getRoomDetail(roomId: '31420211');
    
    final data = detail.data as HuyaUrlDataModel;
    print('lines: ${data.lines.length}');
    print('bitRates: ${data.bitRates.length}');
    print('uid: ${data.uid}');
    
    for (var i = 0; i < data.lines.length; i++) {
      print('line $i: ${data.lines[i].cdnType} ${data.lines[i].line}');
    }
    
    for (var i = 0; i < data.bitRates.length; i++) {
      print('bitrate $i: ${data.bitRates[i].name} ${data.bitRates[i].bitRate}');
    }
  }, timeout: Timeout(Duration(seconds: 30)));
}
