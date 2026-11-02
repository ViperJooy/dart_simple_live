import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  final detail = await site.getRoomDetail(roomId: '31420211');
  final qualities = await site.getPlayQualites(detail: detail);
  final playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
  
  print('线路数: ${playUrls.urls.length}');
  for (var i = 0; i < playUrls.urls.length; i++) {
    print('  $i: ${playUrls.urls[i].substring(0, 80)}...');
  }
  
  if (playUrls.urls.isEmpty) {
    print('无线路');
    exit(1);
  }
  
  final url = playUrls.urls[0]; // 用第一条线路
  
  print('\\n测试 1: 不带任何 header');
  var r = await Process.run('bash', ['-c', '''
    mpv --no-video --ao=null --length=20 \\
      "$url" 2>&1 | grep -E "prematurely|Cache|A:|Exiting" | tail -5
  ''']);
  print(r.stdout);
  
  print('\\n测试 2: 只带 user-agent');
  r = await Process.run('bash', ['-c', '''
    mpv --no-video --ao=null --length=20 \\
      --user-agent="Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0" \\
      "$url" 2>&1 | grep -E "prematurely|Cache|A:|Exiting" | tail -5
  ''']);
  print(r.stdout);
  
  exit(0);
}
