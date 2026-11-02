import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  final detail = await site.getRoomDetail(roomId: '31420211');
  final urlData = detail.data as HuyaUrlDataModel;
  
  print('房间: ${detail.title}');
  print('线路数: ${urlData.lines.length}');
  
  for (var i = 0; i < urlData.lines.length; i++) {
    final line = urlData.lines[i];
    print('\\n=== 线路 $i: ${line.cdnType} ===');
    print('域名: ${line.line}');
    print('hlsAntiCode 前50: ${line.hlsAntiCode.substring(0, line.hlsAntiCode.length > 50 ? 50 : line.hlsAntiCode.length)}...');
    print('flvAntiCode 前50: ${line.flvAntiCode.substring(0, line.flvAntiCode.length > 50 ? 50 : line.flvAntiCode.length)}...');
    print('相同: ${line.hlsAntiCode == line.flvAntiCode}');
    
    // 测试 FLV
    final flvAnti = site.processAnticode(line.flvAntiCode, urlData.uid, line.streamName);
    final flvUrl = '${line.line}/${line.streamName}.flv?$flvAnti&codec=264';
    
    print('\\nFLV URL 测试...');
    final r = await Process.run('bash', ['-c', '''
      mpv --no-video --ao=null --length=10 \\
        --user-agent="Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0" \\
        "$flvUrl" 2>&1 | grep -E "prematurely|Cache|A:|Exiting|403" | tail -5
    ''']);
    print(r.stdout);
  }
  
  exit(0);
}
