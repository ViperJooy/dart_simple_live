import 'dart:async';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  final roomId = '31420211';
  final startTime = DateTime.now();
  var cycleCount = 0;
  var totalPlaySeconds = 0;
  var prematureCount = 0;
  
  print('开始循环测试房间 $roomId，模拟断流重拉...');
  print('开始时间: $startTime');
  
  // 模拟 10 分钟内的多次断流重拉
  while (DateTime.now().difference(startTime).inMinutes < 10) {
    cycleCount++;
    final cycleStart = DateTime.now();
    
    // 获取播放地址（模拟 refreshPlayUrls）
    final detail = await site.getRoomDetail(roomId: roomId);
    final qualities = await site.getPlayQualites(detail: detail);
    final playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
    
    if (playUrls.urls.isEmpty) {
      print('[$cycleCount] 获取地址失败');
      await Future.delayed(Duration(seconds: 5));
      continue;
    }
    
    final url = playUrls.urls[1]; // TX 线路
    
    // 播放 60 秒（模拟正常观看）
    final process = await Process.start('mpv', [
      '--no-video', '--ao=null', '--length=60',
      '--user-agent=${playUrls.headers?['user-agent'] ?? ''}',
      url,
    ]);
    
    var endedPrematurely = false;
    var lastCacheTime = '';
    
    process.stdout.transform(SystemEncoding().decoder).listen((data) {
      for (final line in data.split('\n')) {
        if (line.contains('prematurely')) {
          endedPrematurely = true;
        }
        if (line.contains('Cache:')) {
          lastCacheTime = line.trim();
        }
      }
    });
    
    await process.exitCode.timeout(Duration(seconds: 65), onTimeout: () {
      process.kill();
      return -1;
    });
    
    final cycleDuration = DateTime.now().difference(cycleStart).inSeconds;
    totalPlaySeconds += cycleDuration;
    if (endedPrematurely) prematureCount++;
    
    print('[$cycleCount] 播放 ${cycleDuration}s, prematurely=$endedPrematurely');
    
    if (endedPrematurely) {
      print('  ⚠️ 检测到断流，2 秒后重拉...');
      await Future.delayed(Duration(seconds: 2));
    } else {
      await Future.delayed(Duration(seconds: 1));
    }
  }
  
  final totalDuration = DateTime.now().difference(startTime).inSeconds;
  print('\\n========== 测试结束 ==========');
  print('总时长: ${totalDuration}s');
  print('循环次数: $cycleCount');
  print('断流次数: $prematureCount');
  print('总播放时间: ${totalPlaySeconds}s');
  print('平均每轮播放: ${totalPlaySeconds / cycleCount}s');
  
  exit(0);
}
