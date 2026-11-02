import 'dart:async';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  final roomId = '31420211';
  final startTime = DateTime.now();
  var cycleCount = 0;
  var prematureCount = 0;
  var successCount = 0;
  var failCount = 0;
  
  print('开始 30 分钟断流重拉测试: $roomId');
  print('开始时间: $startTime');
  
  // 初始获取
  var detail = await site.getRoomDetail(roomId: roomId);
  var qualities = await site.getPlayQualites(detail: detail);
  var playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
  
  if (playUrls.urls.isEmpty) {
    print('初始获取地址失败');
    exit(1);
  }
  
  print('初始线路数: ${playUrls.urls.length}');
  
  while (DateTime.now().difference(startTime).inMinutes < 30) {
    cycleCount++;
    final cycleStart = DateTime.now();
    
    // 播放 60 秒
    final url = playUrls.urls.first;
    final process = await Process.start('mpv', [
      '--no-video', '--ao=null', '--length=60',
      '--user-agent=${playUrls.headers?['user-agent'] ?? ''}',
      url,
    ]);
    
    var endedPrematurely = false;
    process.stdout.transform(SystemEncoding().decoder).listen((data) {
      if (data.contains('prematurely')) {
        endedPrematurely = true;
      }
    });
    
    await process.exitCode.timeout(Duration(seconds: 65), onTimeout: () {
      process.kill();
      return -1;
    });
    
    final playSeconds = DateTime.now().difference(cycleStart).inSeconds;
    
    if (endedPrematurely) {
      prematureCount++;
      print('[$cycleCount] 播放 ${playSeconds}s 后断流');
      
      // 模拟 refreshPlayUrls：重新获取房间详情
      await Future.delayed(Duration(seconds: 2));
      
      try {
        final newDetail = await site.getRoomDetail(roomId: roomId);
        final newData = newDetail.data as HuyaUrlDataModel;
        
        if (newData.lines.isNotEmpty) {
          // 新线路可用
          detail = newDetail;
          qualities = await site.getPlayQualites(detail: detail);
          playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
          
          if (playUrls.urls.isNotEmpty) {
            successCount++;
            print('  ✓ 重拉成功，新线路数: ${playUrls.urls.length}');
          } else {
            failCount++;
            print('  ✗ 重拉后地址为空');
          }
        } else {
          // 线路为空，沿用旧线路重新签名
          print('  接口返回空线路，沿用旧线路');
          playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
          if (playUrls.urls.isNotEmpty) {
            successCount++;
            print('  ✓ 旧线路重签名成功');
          } else {
            failCount++;
            print('  ✗ 旧线路重签名失败');
          }
        }
      } catch (e) {
        failCount++;
        print('  ✗ 重拉异常: $e');
      }
    } else {
      print('[$cycleCount] 正常播放 ${playSeconds}s');
      successCount++;
    }
    
    // 每 10 轮打印一次统计
    if (cycleCount % 10 == 0) {
      final elapsed = DateTime.now().difference(startTime).inMinutes;
      print('\\n--- 统计 (${elapsed}分钟) ---');
      print('总轮数: $cycleCount, 断流: $prematureCount, 成功: $successCount, 失败: $failCount');
      print('断流率: ${(prematureCount / cycleCount * 100).toStringAsFixed(1)}%');
      print('');
    }
  }
  
  final totalMinutes = DateTime.now().difference(startTime).inMinutes;
  print('\\n========== 30 分钟测试结束 ==========');
  print('总时长: ${totalMinutes}分钟');
  print('总轮数: $cycleCount');
  print('断流次数: $prematureCount');
  print('恢复成功: $successCount');
  print('恢复失败: $failCount');
  print('断流率: ${(prematureCount / cycleCount * 100).toStringAsFixed(1)}%');
  print('恢复成功率: ${(successCount / (successCount + failCount) * 100).toStringAsFixed(1)}%');
  
  // 如果恢复成功率 >= 90%，认为测试通过
  if (failCount == 0 || successCount / (successCount + failCount) >= 0.9) {
    print('\\n✓ 测试通过');
    exit(0);
  } else {
    print('\\n✗ 测试失败');
    exit(1);
  }
}
