import 'dart:convert';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  // 检查 roomProfile 的 liveLineUrl
  final resultText = await HttpClient.instance.getText(
    "https://m.huya.com/31420211",
    queryParameters: {},
    header: {"user-agent": "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0"},
  );
  
  // 查找 liveLineUrl
  final match = RegExp(r'"liveLineUrl":"([^"]*)"').firstMatch(resultText);
  if (match != null) {
    final encoded = match.group(1)!;
    print('liveLineUrl encoded: $encoded');
    if (encoded.isNotEmpty) {
      try {
        final decoded = utf8.decode(base64.decode(encoded));
        print('liveLineUrl decoded: $decoded');
      } catch (e) {
        print('decode error: $e');
      }
    } else {
      print('liveLineUrl is empty');
    }
  }
  
  // 检查 roomInfo 里是否有其他流信息
  print('\\n检查 roomInfo 中的流相关字段...');
  final roomInfoMatch = RegExp(r'"roomInfo":\{[\s\S]*?\}(?=,"roomProfile")').firstMatch(resultText);
  if (roomInfoMatch != null) {
    final roomInfoText = roomInfoMatch.group(0)!;
    // 查找所有 url 相关字段
    final urlMatches = RegExp(r'"s\w*Url":"([^"]+)"').allMatches(roomInfoText);
    print('URL fields found: ${urlMatches.length}');
    for (final m in urlMatches.take(10)) {
      print('  ${m.group(0)}');
    }
  }
  
  exit(0);
}
