import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  final detail = await site.getRoomDetail(roomId: '31420211');
  print('detail.data type: ${detail.data.runtimeType}');
  
  final qualities = await site.getPlayQualites(detail: detail);
  print('qualities: ${qualities.length}');
  for (var q in qualities) {
    print('  ${q.quality}: bitRate=${q.data["bitRate"]}, urls=${q.data["urls"]?.length}');
  }
  
  if (qualities.isNotEmpty) {
    final playUrls = await site.getPlayUrls(detail: detail, quality: qualities.first);
    print('playUrls: ${playUrls.urls.length}');
  }
  
  exit(0);
}
