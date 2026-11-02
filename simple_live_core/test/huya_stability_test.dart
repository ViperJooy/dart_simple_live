import 'dart:async';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  // 测试 3 个房间，每个 5 分钟
  final rooms = ['31420211', '10188', '988'];
  
  for (final roomId in rooms) {
    print('\\n========== 房间 $roomId ==========');
    
    final detail = await site.getRoomDetail(roomId: roomId);
    if (!detail.status) {
      print('未开播，跳过');
      continue;
    }
    
    final qualities = await site.getPlayQualites(detail: detail);
    final playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
    
    if (playUrls.urls.length < 2) {
      print('线路不足，跳过');
      continue;
    }
    
    final url = playUrls.urls[1]; // TX 线路
    print('标题: ${detail.title}');
    print('清晰度: ${qualities.first.quality}');
    
    // 用 mpv 播放 300 秒（5 分钟），记录断流事件
    final startTime = DateTime.now();
    var prematureCount = 0;
    var lastPosition = Duration.zero;
    
    final process = await Process.start('mpv', [
      '--no-video', '--ao=null',
      '--user-agent=${playUrls.headers?['user-agent'] ?? ''}',
      url,
    ]);
    
    process.stdout.transform(SystemEncoding().decoder).listen((data) {
      for (final line in data.split('\n')) {
        if (line.contains('prematurely')) {
          prematureCount++;
          print('  [${DateTime.now().difference(startTime).inSeconds}s] 断流: $line');
        }
        if (line.contains('A:')) {
          // 解析播放位置
          final match = RegExp(r'A: (\d+):(\d+):(\d+)').firstMatch(line);
          if (match != null) {
            final h = int.parse(match.group(1)!);
            final m = int.parse(match.group(2)!);
            final s = int.parse(match.group(3)!);
            lastPosition = Duration(hours: h, minutes: m, seconds: s);
          }
        }
      }
    });
    
    // 5 分钟后停止
    await Future.delayed(Duration(minutes: 5));
    process.kill();
    await process.exitCode;
    
    final duration = DateTime.now().difference(startTime).inSeconds;
    print('\\n结果:');
    print('  播放时长: ${lastPosition.inSeconds}s');
    print('  实际耗时: ${duration}s');
    print('  断流次数: $prematureCount');
    
    if (prematureCount == 0) {
      print('  ✓ 稳定');
    } else {
      print('  ✗ 不稳定');
    }
  }
  
  exit(0);
}
