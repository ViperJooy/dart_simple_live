import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  final detail = await site.getRoomDetail(roomId: '31420211');
  final qualities = await site.getPlayQualites(detail: detail);
  final playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
  
  final url = playUrls.urls[1]; // TX 线路
  
  print('测试 60 秒播放...');
  final process = await Process.start('mpv', [
    '--no-video', '--ao=null', '--length=60',
    '--user-agent=${playUrls.headers?['user-agent'] ?? ''}',
    url,
  ]);
  
  var output = StringBuffer();
  process.stdout.transform(SystemEncoding().decoder).listen((data) {
    output.write(data);
  });
  process.stderr.transform(SystemEncoding().decoder).listen((data) {
    output.write(data);
  });
  
  await process.exitCode.timeout(Duration(seconds: 70), onTimeout: () {
    process.kill();
    return -1;
  });
  
  final text = output.toString();
  print('\\n关键日志:');
  for (final line in text.split('\n')) {
    if (line.contains('prematurely') || 
        line.contains('Cache') || 
        line.contains('A:') || 
        line.contains('Exiting') ||
        line.contains('error') ||
        line.contains('403') ||
        line.contains('EOF') ||
        line.contains('end of file')) {
      print(line);
    }
  }
  
  exit(0);
}
