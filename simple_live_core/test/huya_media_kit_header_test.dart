import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  final detail = await site.getRoomDetail(roomId: '31420211');
  final qualities = await site.getPlayQualites(detail: detail);
  final playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
  
  final url = playUrls.urls[1];
  final headers = playUrls.headers!;
  
  print('URL: $url');
  print('Headers: $headers');
  
  // 模拟 media_kit 的行为：用 mpv 的 --http-header-fields
  final headerFields = headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  
  print('\\n测试 media_kit 方式的 header 传递...');
  final r = await Process.run('bash', ['-c', '''
    mpv --no-video --ao=null --length=15 \\
      --msg-level=ffmpeg=trace \\
      --user-agent="${headers['user-agent']}" \\
      --http-header-fields="$headerFields" \\
      "$url" 2>&1 | grep -E "http:.*request|http:.*User-Agent|prematurely|Cache|A:|Exiting" | head -20
  ''']);
  print(r.stdout);
  
  exit(0);
}
