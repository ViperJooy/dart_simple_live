import 'dart:convert';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  
  // 获取原始 HTML
  final resultText = await HttpClient.instance.getText(
    "https://m.huya.com/31420211",
    queryParameters: {},
    header: {"user-agent": "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0"},
  );
  
  // 提取 HNF_GLOBAL_INIT
  var text = RegExp(
    r"window\.HNF_GLOBAL_INIT.=.\{[\s\S]*?\}[\s\S]*?</script>",
    multiLine: false,
  ).firstMatch(resultText)?.group(0);
  
  if (text == null) {
    print('HNF_GLOBAL_INIT not found');
    exit(1);
  }
  
  var jsonText = text
      .replaceAll(RegExp(r"window\.HNF_GLOBAL_INIT.=."), '')
      .replaceAll("</script>", "")
      .replaceAllMapped(RegExp(r'function.*?\(.*?\).\{[\s\S]*?\}'), (match) => '""');
  
  var jsonObj = json.decode(jsonText);
  var tLiveInfo = jsonObj["roomInfo"]["tLiveInfo"];
  
  // 检查所有可能的流字段
  print('=== 检查所有流相关字段 ===');
  for (final key in tLiveInfo.keys.toList()) {
    final value = tLiveInfo[key];
    if (value.toString().contains('flv') || 
        value.toString().contains('hls') || 
        value.toString().contains('stream') ||
        value.toString().contains('url') ||
        value.toString().contains('Stream')) {
      print('$key: ${value.toString().substring(0, value.toString().length > 200 ? 200 : value.toString().length)}');
    }
  }
  
  // 检查 tLiveStreamInfo 的完整结构
  print('\\n=== tLiveStreamInfo 完整结构 ===');
  print(JsonEncoder.withIndent('  ').convert(tLiveInfo["tLiveStreamInfo"]));
  
  exit(0);
}
