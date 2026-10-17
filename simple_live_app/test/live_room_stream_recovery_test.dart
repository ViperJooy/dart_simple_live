import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('重试次数耗尽后的持续缓冲仍会重新拉流', () async {
    const wakelockChannel =
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(wakelockChannel, (_) async {
      return const StandardMessageCodec().encodeMessage([null]);
    });
    addTearDown(() => messenger.setMockMessageHandler(wakelockChannel, null));

    final controller = _RecoveryController();
    controller.detail.value = LiveRoomDetail(
      roomId: '123',
      title: '测试直播间',
      cover: '',
      userName: '测试主播',
      userAvatar: '',
      online: 1,
      status: true,
      data: '',
      danmakuData: '123',
      url: 'https://www.douyu.com/123',
    );
    controller.liveStatus.value = true;
    controller.qualites.add(LivePlayQuality(quality: '原画', data: null));
    controller.playUrls.add('https://example.com/live.flv');
    controller.currentLineIndex = 0;

    // 模拟同一次断流已经用完 mediaEnd 的两次自动重试。
    controller.mediaErrorRetryCount = 2;
    controller.mediaEnd();
    await Future<void>.delayed(Duration.zero);

    // 持续缓冲的看门狗仍应能拉取新地址，而不是被 liveStatus=false 永久禁用。
    expect(controller.liveStatus.value, isTrue);
    expect(await controller.handleStreamStall(), isTrue);
  });
}

class _RecoveryController extends LiveRoomController {
  _RecoveryController()
      : super(
          pSite: Site(
            id: 'douyu',
            liveSite: DouyuSite(),
            logo: '',
            name: '斗鱼直播',
          ),
          pRoomId: '123',
        );

  @override
  Future<bool> refreshPlayUrls() async => true;
}
