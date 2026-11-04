import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void testSite(LiveSite site) async {
  var rooms = <LiveRoomItem>[];
  test('getRecommendRooms', () async {
    final result = await site.getRecommendRooms();
    expect(result, isNotNull);
    expect(result.items, isNotEmpty);
    rooms = result.items;
    for (var item in rooms) {
      expect(item.roomId, isNotEmpty);
      expect(item.title, isNotEmpty);
      expect(item.cover, isNotEmpty);
      expect(item.userName, isNotEmpty);
      print(item);
    }
  });

  var categores = <LiveCategory>[];
  test('getCategores', () async {
    categores = await site.getCategores();
    expect(categores, isNotEmpty);
    for (var item in categores) {
      expect(item.name, isNotEmpty);
      for (var subItem in item.children) {
        expect(subItem.name, isNotEmpty);
        expect(subItem.id, isNotEmpty);
        expect(subItem.parentId, isNotEmpty);
      }
      print('${item.name}\n${item.children}');
    }
  });

  test('getCategoryRooms', () async {
    var result = await site.getCategoryRooms(categores.first.children.first);
    expect(result, isNotNull);
    expect(result.items, isNotEmpty);
    for (var item in result.items) {
      expect(item.roomId, isNotEmpty);
      expect(item.title, isNotEmpty);
      expect(item.cover, isNotEmpty);
      expect(item.userName, isNotEmpty);
      print(item);
    }
  });

  test('searchRooms', () async {
    var result = await site.searchRooms('LOL');
    expect(result, isNotNull);
    expect(result.items, isNotEmpty);
    for (var item in result.items) {
      expect(item.roomId, isNotEmpty);
      expect(item.title, isNotEmpty);
      expect(item.cover, isNotEmpty);
      expect(item.userName, isNotEmpty);
      print(item);
    }
  });

  test('searchAnchors', () async {
    // 跳过抖音测试此项
    if (site is DouyinSite) {
      return;
    }
    var result = await site.searchAnchors('联盟');
    expect(result, isNotNull);
    expect(result.items, isNotEmpty);
    for (var item in result.items) {
      expect(item.roomId, isNotEmpty);
      expect(item.userName, isNotEmpty);
      print(item);
    }
  });

  LiveRoomDetail? roomDetail;
  test('getRoomDetail', () async {
    roomDetail = await site.getRoomDetail(roomId: rooms.first.roomId);
    expect(roomDetail, isNotNull);
    expect(roomDetail?.roomId, isNotEmpty);
    expect(roomDetail?.danmakuData, isNotNull);
    print(roomDetail);
  });

  List<LivePlayQuality> playQualities = [];
  test('getPlayQuality', () async {
    playQualities = await site.getPlayQualites(detail: roomDetail!);
    expect(playQualities, isNotEmpty);
    for (var item in playQualities) {
      expect(item.quality, isNotEmpty);
      expect(item.data, isNotNull);
      print(item);
    }
  });

  test('getPlayUrls', () async {
    var url = await site.getPlayUrls(
      detail: roomDetail!,
      quality: playQualities.first,
    );
    expect(url, isNotNull);
    expect(url.urls, isNotEmpty);
    print(url.urls.join('\n\n'));
  });

  test('getDanmaku', () async {
    var danmaku = site.getDanmaku();
    expect(danmaku, isNotNull);
    expect(danmaku, isA<LiveDanmaku>());
    var closed = false;
    var ready = false;
    danmaku.onReady = () {
      print('ready');
      ready = true;
    };
    danmaku.onClose = (msg) {
      print('onClose $msg');
      closed = true;
    };
    var msgCount = 0;
    danmaku.onMessage = (LiveMessage msg) {
      print('onMessage ${msg.type} ${msg.message}');
      msgCount++;
    };
    await danmaku.start(roomDetail!.danmakuData);
    // 接收30秒的弹幕
    await Future.delayed(const Duration(seconds: 30));
    expect(ready, isTrue);
    expect(closed, isFalse);
    expect(msgCount, greaterThan(0));
    await danmaku.stop();
  }, timeout: const Timeout(Duration(seconds: 40)));
}

void main() {
  CoreLog.requestLogType = RequestLogType.short;

  test(
    'Huya builds playback URLs from room FLV anticodes without WUP request',
    () async {
      final site = HuyaSite();
      final detail = LiveRoomDetail(
        cover: '',
        online: 1,
        roomId: '10188',
        title: 'test',
        userName: 'test',
        userAvatar: '',
        introduction: '',
        notice: '',
        status: true,
        data: HuyaUrlDataModel(
          url: '',
          uid: '1234567890123',
          lines: [
            HuyaLineModel(
              line: 'https://test.cdn.example',
              lineType: HuyaLineType.flv,
              flvAntiCode:
                  'fm=YWJjX2RlZg%3D%3D&wsTime=67200000&fs=0&ctype=tars_mobile&t=103',
              hlsAntiCode: '',
              streamName: 'test_stream',
              cdnType: 'test',
              presenterUid: 10188,
            ),
          ],
          bitRates: [HuyaBitRateModel(name: '高清', bitRate: 2000)],
        ),
        danmakuData: HuyaDanmakuArgs(ayyuid: 1, topSid: 1, subSid: 1),
        url: 'https://www.huya.com/10188',
      );
      final quality = (await site.getPlayQualites(detail: detail)).single;

      final playUrls = await site.getPlayUrls(detail: detail, quality: quality);

      expect(playUrls.urls, hasLength(1));
      final uri = Uri.parse(playUrls.urls.single);
      expect(uri.host, 'test.cdn.example');
      expect(uri.path, '/test_stream.flv');
      expect(uri.queryParameters['ctype'], 'tars_mobile');
      expect(uri.queryParameters['t'], '103');
      expect(uri.queryParameters['ratio'], '2000');
      expect(
        uri.queryParameters['wsSecret'],
        matches(RegExp(r'^[0-9a-f]{32}$')),
      );
    },
  );

  group('bilibili tests', () {
    testSite(BiliBiliSite());
  });

  group('douyu tests', () {
    testSite(DouyuSite());
  });

  group('huya tests', () {
    testSite(HuyaSite());
  });

  group('douyin tests', () {
    testSite(DouyinSite());
  });
}
