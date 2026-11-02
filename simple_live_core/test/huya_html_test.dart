import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

void main() {
  test('check raw html', () async {
    final resultText = await HttpClient.instance.getText(
      "https://m.huya.com/31420211",
      queryParameters: {},
      header: {"user-agent": "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 Edg/117.0.0.0"},
    );
    
    // 查找 vStreamInfo
    final streamInfoMatch = RegExp(r'"vStreamInfo"\s*:\s*\{[^}]+\}').firstMatch(resultText);
    if (streamInfoMatch != null) {
      print('vStreamInfo found: ${streamInfoMatch.group(0)!.substring(0, 200)}');
    } else {
      print('vStreamInfo not found');
    }
    
    // 查找 sFlvUrl
    final flvMatches = RegExp(r'"sFlvUrl"\s*:\s*"([^"]+)"').allMatches(resultText);
    print('sFlvUrl count: ${flvMatches.length}');
    for (final m in flvMatches.take(5)) {
      print('  ${m.group(1)}');
    }
    
    // 查找 sHlsUrl
    final hlsMatches = RegExp(r'"sHlsUrl"\s*:\s*"([^"]+)"').allMatches(resultText);
    print('sHlsUrl count: ${hlsMatches.length}');
    for (final m in hlsMatches.take(5)) {
      print('  ${m.group(1)}');
    }
  }, timeout: Timeout(Duration(seconds: 30)));
}
