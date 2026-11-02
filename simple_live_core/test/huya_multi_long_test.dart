import 'dart:async';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  // 测试多个房间
  final roomIds = ['31420211', '10188', '988'];
  final results = <String, List<String>>{};
  
  for (final roomId in roomIds) {
    results[roomId] = [];
  }
  
  // 并行测试
  await Future.wait(roomIds.map((roomId) => testRoom(site, roomId, results[roomId]!)));
  
  // 打印结果
  print('\\n========== 测试结果汇总 ==========');
  for (final entry in results.entries) {
    print('\\n房间 ${entry.key}:');
    for (final line in entry.value) {
      print('  $line');
    }
  }
  
  exit(0);
}

Future<void> testRoom(HuyaSite site, String roomId, List<String> logs) async {
  try {
    final detail = await site.getRoomDetail(roomId: roomId);
    logs.add('房间: ${detail.title}');
    
    if (!detail.status) {
      logs.add('未开播，跳过');
      return;
    }
    
    final qualities = await site.getPlayQualites(detail: detail);
    final playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
    
    logs.add('清晰度: ${qualities.first.quality}');
    logs.add('线路数: ${playUrls.urls.length}');
    
    // 测试 TX 线路（线路 1）
    if (playUrls.urls.length < 2) {
      logs.add('线路不足，跳过');
      return;
    }
    
    final url = playUrls.urls[1];
    logs.add('测试地址: ${url.substring(0, url.length > 60 ? 60 : url.length)}...');
    
    // 用 mpv 播放 30 分钟，记录关键事件
    final process = await Process.start('mpv', [
      '--no-video', '--ao=null',
      '--user-agent=${playUrls.headers?['user-agent'] ?? ''}',
      url,
    ]);
    
    var lastLogTime = DateTime.now();
    var dataReceived = false;
    var streamEnded = false;
    var errorOccurred = false;
    
    process.stdout.transform(SystemEncoding().decoder).listen((data) {
      dataReceived = true;
      for (final line in data.split('\n')) {
        if (line.contains('prematurely')) {
          logs.add('[${DateTime.now()}] 流提前结束: $line');
          streamEnded = true;
        }
        if (line.contains('error') || line.contains('403')) {
          logs.add('[${DateTime.now()}] 错误: $line');
          errorOccurred = true;
        }
        if (line.contains('Exiting')) {
          logs.add('[${DateTime.now()}] 退出: $line');
          streamEnded = true;
        }
      }
    });
    
    process.stderr.transform(SystemEncoding().decoder).listen((data) {
      for (final line in data.split('\n')) {
        if (line.contains('error') || line.contains('403') || line.contains('failed')) {
          logs.add('[${DateTime.now()}] stderr: $line');
          errorOccurred = true;
        }
      }
    });
    
    // 30 分钟后或进程退出
    final timer = Timer(Duration(minutes: 30), () {
      logs.add('[${DateTime.now()}] 30 分钟测试结束，主动关闭');
      process.kill();
    });
    
    await process.exitCode;
    timer.cancel();
    
    if (!dataReceived) {
      logs.add('未收到任何数据');
    } else if (streamEnded) {
      logs.add('流已结束');
    } else if (errorOccurred) {
      logs.add('发生错误');
    } else {
      logs.add('30 分钟播放正常');
    }
    
  } catch (e) {
    logs.add('测试失败: $e');
  }
}
