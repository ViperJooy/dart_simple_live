import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  final detail = await site.getRoomDetail(roomId: '10188');
  final qualities = await site.getPlayQualites(detail: detail);
  final playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
  
  // 测试 TX 线路 FLV 用浏览器 UA
  final urlData = detail.data as HuyaUrlDataModel;
  final txLine = urlData.lines[1];
  final flvAnti = site.processAnticode(txLine.flvAntiCode, urlData.uid, txLine.streamName);
  final flvUrl = '${txLine.line}/${txLine.streamName}.flv?$flvAnti&codec=264';
  
  print('FLV URL: $flvUrl');
  
  // 浏览器 UA
  print('\\n=== 浏览器 UA ===');
  var r = await Process.run('bash', ['-c', '''
    mpv --no-video --ao=null --length=15 \\
      --user-agent="Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0" \\
      "$flvUrl" 2>&1 | grep -E "prematurely|Cache|A:|Exiting" | tail -5
  ''']);
  print(r.stdout);
  
  // HYSDK UA
  print('\\n=== HYSDK UA ===');
  r = await Process.run('bash', ['-c', '''
    mpv --no-video --ao=null --length=15 \\
      --user-agent="HYSDK(Windows, 30000002)_APP(pc_exe&7060000&official)_SDK(trans&2.32.3.5646)" \\
      "$flvUrl" 2>&1 | grep -E "prematurely|Cache|A:|Exiting" | tail -5
  ''']);
  print(r.stdout);
  
  exit(0);
}
