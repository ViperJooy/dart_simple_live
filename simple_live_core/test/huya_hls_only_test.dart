import 'dart:convert';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  
  final resultText = await HttpClient.instance.getText(
    "https://m.huya.com/31420211",
    queryParameters: {},
    header: {"user-agent": "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0"},
  );
  
  // 查找 m3u8
  final hlsMatches = RegExp(r'https?://[^"\s]+\.m3u8[^"\s]*').allMatches(resultText);
  print('m3u8 URLs found: ${hlsMatches.length}');
  for (final m in hlsMatches.take(5)) {
    print('  ${m.group(0)}');
  }
  
  // 查找 sHlsUrl
  final hlsUrlMatches = RegExp(r'"sHlsUrl":"([^"]+)"').allMatches(resultText);
  print('\nsHlsUrl found: ${hlsUrlMatches.length}');
  for (final m in hlsUrlMatches.take(5)) {
    print('  ${m.group(1)}');
  }
  
  // 查找 liveLineUrl
  final lineUrlMatch = RegExp(r'"liveLineUrl":"([^"]*)"').firstMatch(resultText);
  print('\nliveLineUrl: ${lineUrlMatch?.group(1) ?? "not found"}');
  
  // 检查 base64
  final base64Match = RegExp(r'"liveLineUrl":"([A-Za-z0-9+/=]+)"').firstMatch(resultText);
  if (base64Match != null) {
    try {
      final decoded = utf8.decode(base64.decode(base64Match.group(1)!));
      print('decoded: $decoded');
    } catch (e) {
      print('decode failed: $e');
    }
  }
  
  exit(0);
}
