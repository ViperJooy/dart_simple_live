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
  
  // 检查 tLiveInfo
  var tLiveInfo = jsonObj["roomInfo"]["tLiveInfo"];
  print('tLiveInfo keys: ${tLiveInfo.keys.toList()}');
  
  // 检查 tLiveStreamInfo
  var streamInfo = tLiveInfo["tLiveStreamInfo"];
  print('tLiveStreamInfo keys: ${streamInfo.keys.toList()}');
  print('vStreamInfo: ${streamInfo["vStreamInfo"]}');
  print('vBitRateInfo: ${streamInfo["vBitRateInfo"]}');
  
  // 检查 roomProfile
  var roomProfile = jsonObj["roomProfile"];
  print('\\nroomProfile keys: ${roomProfile.keys.toList()}');
  print('liveLineUrl: ${roomProfile["liveLineUrl"]}');
  
  // 检查 tRecentLive
  var tRecentLive = jsonObj["roomInfo"]["tRecentLive"];
  print('\\ntRecentLive keys: ${tRecentLive.keys.toList()}');
  print('lMultiStreamFlag: ${tRecentLive["lMultiStreamFlag"]}');
  print('iBitRate: ${tRecentLive["iBitRate"]}');
  print('iIsBluRay: ${tRecentLive["iIsBluRay"]}');
  print('sBluRayMBitRate: ${tRecentLive["sBluRayMBitRate"]}');
  
  exit(0);
}
