import 'dart:convert';
import 'dart:io';
import 'package:simple_live_core/simple_live_core.dart';

void main() async {
  CoreLog.requestLogType = RequestLogType.short;
  final site = HuyaSite();
  
  // 直接调用 getRoomDetail
  final detail = await site.getRoomDetail(roomId: '31420211');
  final data = detail.data as HuyaUrlDataModel;
  
  print('detail.data lines: ${data.lines.length}');
  print('detail.data bitRates: ${data.bitRates.length}');
  print('detail.data uid: ${data.uid}');
  print('detail.data url: ${data.url}');
  
  // 检查 roomProfile
  print('\\n检查 roomProfile...');
  
  // 尝试用 tupClient 获取
  print('\\n尝试 tupClient...');
  try {
    final token = await site.getCndTokenInfoEx('31420211');
    print('CDN token: $token');
  } catch (e) {
    print('tupClient 失败: $e');
  }
  
  exit(0);
}
