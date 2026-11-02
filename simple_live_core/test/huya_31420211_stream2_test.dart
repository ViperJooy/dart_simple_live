import 'dart:convert';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  
  // 尝试用 search API 找到这个房间的流信息
  print('=== 搜索房间信息 ===');
  try {
    final result = await HttpClient.instance.getJson(
      "https://search.cdn.huya.com/",
      queryParameters: {
        "m": "Search",
        "do": "getSearchContent",
        "q": "31420211",
        "uid": 0,
        "v": 4,
        "typ": -5,
        "livestate": 0,
        "rows": 20,
        "start": 0,
      },
    );
    final data = json.decode(result);
    print('搜索结果: ${data["response"]["3"]["numFound"]}');
    if (data["response"]["3"]["docs"].isNotEmpty) {
      final doc = data["response"]["3"]["docs"][0];
      print('房间: ${doc["game_roomName"]}');
      print('room_id: ${doc["room_id"]}');
    }
  } catch (e) {
    print('搜索失败: $e');
  }
  
  // 尝试直接访问 www.huya.com/31420211
  print('\\n=== www.huya.com ===');
  try {
    final resultText = await HttpClient.instance.getText(
      "https://www.huya.com/31420211",
      queryParameters: {},
      header: {"user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
    );
    
    // 查找 stream 相关
    final streamMatches = RegExp(r'"stream":\{[^}]+\}').allMatches(resultText);
    print('stream found: ${streamMatches.length}');
    
    // 查找 flv
    final flvMatches = RegExp(r'https?://[^"\s]+\.flv[^"\s]*').allMatches(resultText);
    print('flv URLs: ${flvMatches.length}');
    for (final m in flvMatches.take(3)) {
      print('  ${m.group(0)}');
    }
    
    // 查找 m3u8
    final m3u8Matches = RegExp(r'https?://[^"\s]+\.m3u8[^"\s]*').allMatches(resultText);
    print('m3u8 URLs: ${m3u8Matches.length}');
    for (final m in m3u8Matches.take(3)) {
      print('  ${m.group(0)}');
    }
  } catch (e) {
    print('www 失败: $e');
  }
  
  exit(0);
}
