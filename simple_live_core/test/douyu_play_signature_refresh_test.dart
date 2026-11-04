import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

// DouyuSign.getSign 执行此脚本，并以三个字符串参数调用
// ub98484234(rid, did, tt)。
// 使用人工构造的签名，不包含抓取的房间脚本、凭据或真实签名。
const _signScript = r'''
function ub98484234(rid, did, tt) {
  if (typeof rid !== 'string' || typeof did !== 'string' ||
      typeof tt !== 'string' || !did || !/^\d+$/.test(tt)) {
    throw new Error('Unexpected signing arguments');
  }
  return 'rid=' + rid + '&did=' + did + '&tt=' + tt +
    '&sign=fixture-' + rid + '-' + tt;
}
''';

void main() {
  test('同一 detail 跨秒连续三次 getPlayUrls 应刷新 tt 及对应签名，且保持清晰度和 CDN', () async {
    const roomId = '123456';
    const cdns = ['fixture-cdn-a', 'fixture-cdn-b'];
    const rate = 2;
    final client = HttpClient.instance;
    final originalDio = client.dio;
    final originalEnableLog = CoreLog.enableLog;
    final originalRequestLogType = CoreLog.requestLogType;
    final dio = Dio();
    final playRequests = <Map<String, String>>[];
    final unexpectedRequests = <String>[];

    addTearDown(() {
      client.dio = originalDio;
      CoreLog.enableLog = originalEnableLog;
      CoreLog.requestLogType = originalRequestLogType;
      dio.close(force: true);
    });
    CoreLog.enableLog = false;
    CoreLog.requestLogType = RequestLogType.none;
    client.dio = dio;

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          Object? response;
          if (options.uri.host == 'www.douyu.com') {
            if (options.method == 'GET' &&
                options.uri.path == '/betard/$roomId') {
              response = {
                'room': {
                  'room_id': int.parse(roomId),
                  'room_name': 'Fixture room',
                  'room_pic': 'https://fixture.invalid/cover.jpg',
                  'owner_name': 'Fixture anchor',
                  'owner_avatar': 'https://fixture.invalid/avatar.jpg',
                  'show_details': 'Offline fixture',
                  'room_biz_all': {'hot': '1'},
                  'show_status': 1,
                  'videoLoop': 0,
                },
              };
            } else if (options.method == 'GET' &&
                options.uri.path == '/swf_api/h5room/$roomId') {
              // 省略 show_time，避免生产代码打印开播时长。
              response = {'data': <String, Object>{}};
            } else if (options.method == 'GET' &&
                options.uri.path == '/swf_api/homeH5Enc' &&
                options.uri.queryParameters['rids'] == roomId) {
              response = jsonEncode({
                'data': {'room$roomId': _signScript},
              });
            } else if (options.method == 'POST' &&
                options.uri.path == '/lapi/live/getH5Play/$roomId') {
              final form = Uri.splitQueryString(options.data as String);
              if (form['rate'] != '-1') {
                playRequests.add(Map<String, String>.of(form));
              }
              response = {
                'error': 0,
                'data': {
                  'cdnsWithName': [
                    for (final cdn in cdns) {'cdn': cdn, 'name': cdn},
                  ],
                  'multirates': [
                    {'name': 'Fixture quality', 'rate': rate},
                  ],
                  'rtmp_url': 'https://fixture.invalid',
                  'rtmp_live': '${form['cdn']}.flv',
                },
              };
            }
          }
          if (response == null) {
            // 未匹配的请求一律拒绝，不转发至真实网络适配器。
            unexpectedRequests.add('${options.method} ${options.uri.path}');
            handler.reject(
              DioException(
                requestOptions: options,
                error: 'Unexpected offline fixture request',
              ),
            );
            return;
          }
          handler.resolve(
            Response<Object>(
              requestOptions: options,
              statusCode: 200,
              data: response,
            ),
          );
        },
      ),
    );

    final site = DouyuSite();
    // 通过真实的 DouyuSign.getSign 和 QuickJS 实现生成签名。
    final detail = await site.getRoomDetail(roomId: roomId);
    final initialForm = Uri.splitQueryString(detail.data as String);
    expect(initialForm['sign'], 'fixture-$roomId-${initialForm['tt']}');
    expect(initialForm['did'], isNotEmpty);
    final quality = (await site.getPlayQualites(detail: detail)).single;
    final selection = quality.data as DouyuPlayData;
    expect(selection.rate, rate);
    expect(selection.cdns, cdns);

    final windows = <({int start, int end})>[];
    final requestsByCall = <List<Map<String, String>>>[];
    for (var call = 0; call < 3; call++) {
      // 创建签名及各轮重试之间均间隔一秒以上，即使 DouyuSign 向上取整也能跨秒。
      // 此处不能替换 detail.data；由外部刷新房间详情会掩盖这个回归问题。
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final offset = playRequests.length;
      final start = DateTime.now().millisecondsSinceEpoch;
      final urls = await site.getPlayUrls(detail: detail, quality: quality);
      final end = DateTime.now().millisecondsSinceEpoch;
      windows.add((start: start, end: end));
      requestsByCall.add(playRequests.sublist(offset));
      expect(urls.urls, [
        for (final cdn in cdns) 'https://fixture.invalid/$cdn.flv',
      ]);
      expect(quality.data, same(selection));
      expect(selection.rate, rate);
      expect(selection.cdns, cdns);
    }

    expect(unexpectedRequests, isEmpty);
    expect(requestsByCall.map((requests) => requests.length), [2, 2, 2]);
    for (final requests in requestsByCall) {
      expect(requests.map((form) => form['cdn']), cdns);
      for (final form in requests) {
        expect(form['rate'], '$rate');
        expect(form['rid'], roomId);
        expect(form['did'], initialForm['did']);
        expect(int.tryParse(form['tt'] ?? ''), isNotNull);
        // 仅检查 tt 无法发现只更新时间戳、未重新签名的问题。
        expect(form['sign'], 'fixture-$roomId-${form['tt']}');
      }
    }

    // 三轮重试全部完成后再断言签名时效，避免首轮旧签名导致后续重试未执行。
    // 对实际调用区间的起止时间分别向下、向上取整，兼容 DouyuSign 按秒四舍五入。
    final freshByCall = <List<bool>>[];
    for (var call = 0; call < 3; call++) {
      final window = windows[call];
      final earliest = window.start ~/ 1000;
      final latest = (window.end + 999) ~/ 1000;
      freshByCall.add([
        for (final form in requestsByCall[call])
          int.parse(form['tt']!) >= earliest &&
              int.parse(form['tt']!) <= latest,
      ]);
    }
    expect(freshByCall, [
      [true, true],
      [true, true],
      [true, true],
    ], reason: '每次 getPlayUrls 都必须在本次调用时间窗口内重新签名；复用房间详情中的旧签名会导致短流。');
  });
}
