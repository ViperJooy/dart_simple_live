import 'dart:convert';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  
  // 尝试虎牙移动端 API
  final roomId = '31420211';
  
  // 方法 1: 尝试 live.qq.com 或其他接口
  print('=== 尝试获取流地址 ===');
  
  // 方法 2: 检查 roomInfo 里是否有其他线索
  final resultText = await HttpClient.instance.getText(
    "https://m.huya.com/$roomId",
    queryParameters: {},
    header: {"user-agent": "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0"},
  );
  
  // 查找所有可能的流地址模式
  final patterns = [
    r'"(sFlvUrl|sHlsUrl|sStreamName|sCdnType)":"([^"]*)"',
    r'"liveLineUrl":"([^"]*)"',
    r'"stream[^"]*":"([^"]*)"',
    r'https?://[^"\s]+\.(flv|m3u8)[^"\s]*',
  ];
  
  for (final pattern in patterns) {
    final matches = RegExp(pattern).allMatches(resultText);
    if (matches.isNotEmpty) {
      print('\\n模式 $pattern:');
      for (final m in matches.take(5)) {
        print('  ${m.group(0)}');
      }
    }
  }
  
  // 检查 window.__INITIAL_STATE__ 或其他全局变量
  print('\\n=== 检查其他全局变量 ===');
  final scriptMatches = RegExp(r'<script[^>]*>([\s\S]*?)</script>').allMatches(resultText);
  for (final m in scriptMatches) {
    final content = m.group(1)!;
    if (content.contains('flv') || content.contains('hls') || content.contains('stream')) {
      print('找到相关 script: ${content.substring(0, content.length > 200 ? 200 : content.length)}');
    }
  }
  
  exit(0);
}
