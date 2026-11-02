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
  
  var text = RegExp(
    r"window\.HNF_GLOBAL_INIT.=.\{[\s\S]*?\}[\s\S]*?</script>",
    multiLine: false,
  ).firstMatch(resultText)?.group(0);
  
  var jsonText = text!
      .replaceAll(RegExp(r"window\.HNF_GLOBAL_INIT.=."), '')
      .replaceAll("</script>", "")
      .replaceAllMapped(RegExp(r'function.*?\(.*?\).\{[\s\S]*?\}'), (match) => '""');
  
  var jsonObj = json.decode(jsonText);
  var tRecentLive = jsonObj["roomInfo"]["tRecentLive"];
  
  print('tRecentLive:');
  print(JsonEncoder.withIndent('  ').convert(tRecentLive));
  
  // 检查是否有流相关字段
  print('\\n流相关字段:');
  for (final key in tRecentLive.keys.toList()) {
    final value = tRecentLive[key].toString();
    if (value.contains('flv') || value.contains('hls') || value.contains('stream') || value.contains('http')) {
      print('  $key: $value');
    }
  }
  
  exit(0);
}
