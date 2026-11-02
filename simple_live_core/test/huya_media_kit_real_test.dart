import 'dart:async';
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
  
  // 用 media_kit 的方式传 header（通过 --http-header-fields）
  final headerFields = headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  
  print('\\n开始播放 120 秒，观察是否断流...');
  final process = await Process.start('mpv', [
    '--no-video', '--ao=null', '--length=120',
    '--msg-level=ffmpeg=trace',
    '--http-header-fields=$headerFields',
    url,
  ]);
  
  var lastOutput = '';
  process.stdout.transform(SystemEncoding().decoder).listen((data) {
    lastOutput = data;
  });
  
  // 每 10 秒打印一次状态
  for (var i = 0; i < 12; i++) {
    await Future.delayed(Duration(seconds: 10));
    print('[${(i + 1) * 10}s] 播放中...');
  }
  
  process.kill();
  await process.exitCode;
  
  // 分析输出
  final lines = lastOutput.split('\n');
  var hasPremature = false;
  var has403 = false;
  var requestCount = 0;
  
  for (final line in lines) {
    if (line.contains('prematurely')) hasPremature = true;
    if (line.contains('403')) has403 = true;
    if (line.contains('http: request:')) requestCount++;
  }
  
  print('\\n========== 结果 ==========');
  print('HTTP 请求数: $requestCount');
  print('是否 prematurely: $hasPremature');
  print('是否 403: $has403');
  
  exit(0);
}
