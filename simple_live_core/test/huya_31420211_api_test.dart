import 'dart:convert';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  
  // 尝试虎牙的其他 API 获取流信息
  final roomId = '31420211';
  
  // 方法 1: 尝试 www.huya.com 的 cache.php
  print('=== 方法 1: cache.php ===');
  try {
    final result = await HttpClient.instance.getJson(
      "https://www.huya.com/cache.php",
      queryParameters: {
        "m": "Live",
        "do": "getLiveInfo",
        "roomId": roomId,
      },
    );
    print('结果: $result');
  } catch (e) {
    print('失败: $e');
  }
  
  // 方法 2: 尝试获取 m3u8 直接
  print('\\n=== 方法 2: 直接请求 hls ===');
  try {
    // 从 tRecentLive 获取流名称
    final resultText = await HttpClient.instance.getText(
      "https://m.huya.com/$roomId",
      queryParameters: {},
      header: {"user-agent": "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0"},
    );
    
    // 查找 streamName
    final streamMatch = RegExp(r'"lLiveId":(\d+)').firstMatch(resultText);
    if (streamMatch != null) {
      print('lLiveId: ${streamMatch.group(1)}');
    }
    
    // 查找 sStreamName
    final streamNameMatch = RegExp(r'"sStreamName":"([^"]+)"').firstMatch(resultText);
    if (streamNameMatch != null) {
      print('sStreamName: ${streamNameMatch.group(1)}');
    }
  } catch (e) {
    print('失败: $e');
  }
  
  exit(0);
}
