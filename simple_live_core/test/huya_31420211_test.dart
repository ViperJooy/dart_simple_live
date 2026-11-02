import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  final detail = await site.getRoomDetail(roomId: '31420211');
  print('房间: ${detail.title}');
  print('状态: ${detail.status ? "开播" : "未开播"}');
  
  final qualities = await site.getPlayQualites(detail: detail);
  print('清晰度: ${qualities.map((q) => q.quality).toList()}');
  
  // 测试最高清
  final q = qualities.first;
  final playUrls = await site.getPlayUrls(detail: detail, quality: q);
  
  print('\\n播放地址:');
  for (var i = 0; i < playUrls.urls.length; i++) {
    print('  $i: ${playUrls.urls[i]}');
  }
  
  // 测试 HS 线路 30 秒
  if (playUrls.urls.length > 2) {
    final url = playUrls.urls[2]; // HS 线路
    print('\\n测试 HS 线路 30 秒...');
    final r = await Process.run('bash', ['-c', '''
      mpv --no-video --ao=null --length=30 \\
        --user-agent="${playUrls.headers?['user-agent'] ?? ''}" \\
        "$url" 2>&1 | grep -E "prematurely|Cache|A:|Exiting" | tail -10
    ''']);
    print(r.stdout);
  }
  
  exit(0);
}
