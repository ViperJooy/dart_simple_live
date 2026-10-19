import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
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
    addTearDown(controller.disposeStream);
    addTearDown(controller.scrollController.dispose);
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

  group('真实控制器离线恢复调用链', () {
    setUp(() {
      Get.put<AppSettingsController>(_OfflineAppSettingsController());
      const wakelockChannel =
          'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler(wakelockChannel, (_) async {
        return const StandardMessageCodec().encodeMessage([null]);
      });
      addTearDown(() => messenger.setMockMessageHandler(wakelockChannel, null));
      addTearDown(Get.reset);
    });

    test('initPlaylist 将当前选中线路作为 Playlist 的起播 index', () async {
      final platformPlayer = _RecordingPlatformPlayer();
      final controller = _OfflineLiveRoomController(LiveSite(), platformPlayer);
      addTearDown(controller.scrollController.dispose);
      addTearDown(controller.player.dispose);
      addTearDown(controller.disposeStream);
      _seedLiveRoom(controller);
      controller.playUrls.assignAll([
        'http://example.com/line-1.flv',
        'http://example.com/line-2.flv',
        'http://example.com/line-3.flv',
      ]);
      controller.currentLineIndex = 1;
      controller.playHeaders = {'X-Test-Header': 'offline'};
      AppSettingsController.instance.playerForceHttps.value = true;

      await controller.initPlaylist();

      expect(platformPlayer.opened, hasLength(1));
      final playlist = platformPlayer.opened.single as Playlist;
      expect(playlist.medias.map((media) => media.uri), [
        'https://example.com/line-1.flv',
        'https://example.com/line-2.flv',
        'https://example.com/line-3.flv',
      ]);
      expect(playlist.medias[1].httpHeaders, {'X-Test-Header': 'offline'});
      expect(controller.currentLineInfo.value, '线路2');
      expect(platformPlayer.jumps, isEmpty);
      expect(
        playlist.index,
        1,
        reason: '播放器必须直接从选中的线路2起播，而不是默认线路1',
      );
    });

    testWidgets('冷却期内多个 EOF 不重放旧地址且到期只合并重拉一次', (tester) async {
      final liveSite = _BlockedLiveSite();
      // 已完成的 Future 可重复返回，所有刷新仍经过真实站点与播放器边界。
      liveSite.response.complete(LivePlayUrl(
        urls: ['https://example.com/fresh.flv'],
      ));
      final platformPlayer = _RecordingPlatformPlayer();
      final controller = _OfflineLiveRoomController(liveSite, platformPlayer);
      addTearDown(controller.scrollController.dispose);
      addTearDown(controller.player.dispose);
      addTearDown(controller.disposeStream);
      _seedLiveRoom(controller);

      expect(await controller.handleStreamStall(), isTrue);
      expect(liveSite.requestCount, 1);
      expect(platformPlayer.opened, hasLength(1));

      controller.mediaEnd();
      await tester.pump();
      controller.mediaEnd();
      // 同时排空生产回调第二次重试的一秒延迟，不使用真实等待。
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 8));
      final requestsBeforeCooldownEnds = liveSite.requestCount;
      final jumpsBeforeCooldownEnds = List<int>.of(platformPlayer.jumps);

      await tester.pump(const Duration(seconds: 1));
      final requestsAtCooldownEnd = liveSite.requestCount;
      final opensAtCooldownEnd = platformPlayer.opened.length;
      // 再跨过一个完整冷却期，证明多个 EOF 没有留下重复重拉任务。
      await tester.pump(const Duration(seconds: 10));

      expect(
        {
          'requestsBeforeCooldownEnds': requestsBeforeCooldownEnds,
          'jumpsBeforeCooldownEnds': jumpsBeforeCooldownEnds,
          'requestsAtCooldownEnd': requestsAtCooldownEnd,
          'opensAtCooldownEnd': opensAtCooldownEnd,
          'requestsAfterAnotherCooldown': liveSite.requestCount,
          'jumps': platformPlayer.jumps,
        },
        {
          'requestsBeforeCooldownEnds': 1,
          'jumpsBeforeCooldownEnds': <int>[],
          'requestsAtCooldownEnd': 2,
          'opensAtCooldownEnd': 2,
          'requestsAfterAnotherCooldown': 2,
          'jumps': <int>[],
        },
        reason: '冷却应延后并合并取新地址，不能重放旧地址或永久丢掉 EOF',
      );
    });

    testWidgets('disposeStream 取消冷却期间排队的重拉', (tester) async {
      final liveSite = _BlockedLiveSite();
      liveSite.response.complete(LivePlayUrl(
        urls: ['https://example.com/fresh.flv'],
      ));
      final platformPlayer = _RecordingPlatformPlayer();
      final controller = _OfflineLiveRoomController(liveSite, platformPlayer);
      addTearDown(controller.scrollController.dispose);
      addTearDown(controller.player.dispose);
      addTearDown(controller.disposeStream);
      _seedLiveRoom(controller);

      expect(await controller.handleStreamStall(), isTrue);
      expect(liveSite.requestCount, 1);
      expect(platformPlayer.opened, hasLength(1));

      controller.mediaEnd();
      await tester.pump();
      expect(liveSite.requestCount, 1);
      expect(platformPlayer.jumps, isEmpty);

      controller.disposeStream();
      // 跨过冷却到期及下一轮冷却，排队任务不能在销毁后重新取流或播放。
      await tester.pump(const Duration(seconds: 11));
      await tester.pump(const Duration(seconds: 10));

      expect(liveSite.requestCount, 1);
      expect(platformPlayer.opened, hasLength(1));
      expect(platformPlayer.jumps, isEmpty);
    });

    test('disposeStream 后忽略真实刷新中迟到的站点响应', () async {
      final liveSite = _BlockedLiveSite();
      final platformPlayer = _RecordingPlatformPlayer();
      final controller = _OfflineLiveRoomController(liveSite, platformPlayer);
      addTearDown(controller.scrollController.dispose);
      addTearDown(controller.player.dispose);
      addTearDown(controller.disposeStream);
      _seedLiveRoom(controller);
      await controller.initPlaylist();
      expect(platformPlayer.opened, hasLength(1));

      final refresh = controller.refreshPlayUrls();
      await liveSite.requested.future;
      // getPlayUrls 仍被阻塞，先销毁流监听，再交付真实刷新所等待的响应。
      controller.disposeStream();
      liveSite.response.complete(LivePlayUrl(
        urls: ['https://example.com/late.flv'],
      ));

      expect(await refresh, isFalse);
      expect(liveSite.requestCount, 1);
      expect(platformPlayer.opened, hasLength(1),
          reason: '销毁后迟到的新地址不得再次触发 player.open');
      expect(platformPlayer.jumps, isEmpty);
      final initialPlaylist = platformPlayer.opened.single as Playlist;
      expect(initialPlaylist.medias.single.uri, 'https://example.com/old.flv');
    });

    testWidgets('手动切换有效线路后取消冷却期间排队的重拉', (tester) async {
      final liveSite = _BlockedLiveSite();
      liveSite.response.complete(LivePlayUrl(urls: [
        'https://example.com/line-1.flv',
        'https://example.com/line-2.flv',
      ]));
      final platformPlayer = _RecordingPlatformPlayer();
      final controller = _OfflineLiveRoomController(liveSite, platformPlayer);
      addTearDown(controller.scrollController.dispose);
      addTearDown(controller.player.dispose);
      addTearDown(controller.disposeStream);
      _seedLiveRoom(controller);

      expect(await controller.handleStreamStall(), isTrue);
      controller.mediaEnd();
      await tester.pump();
      await controller.changePlayLine(1);
      expect(controller.currentLineIndex, 1);
      expect(platformPlayer.jumps, [1]);

      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      expect(liveSite.requestCount, 1, reason: '用户已主动切换到有效线路，旧 EOF 的排队重拉应被取消');
      expect(platformPlayer.opened, hasLength(1));
      expect(platformPlayer.jumps, [1]);
    });

    testWidgets('开启后台自动暂停时冷却排队等待回到前台才恢复一次', (tester) async {
      AppSettingsController.instance.playerAutoPause.value = true;
      final liveSite = _BlockedLiveSite();
      liveSite.response.complete(LivePlayUrl(
        urls: ['https://example.com/fresh.flv'],
      ));
      final platformPlayer = _RecordingPlatformPlayer();
      final controller = _OfflineLiveRoomController(liveSite, platformPlayer);
      addTearDown(controller.scrollController.dispose);
      addTearDown(controller.player.dispose);
      addTearDown(controller.disposeStream);
      _seedLiveRoom(controller);

      expect(await controller.handleStreamStall(), isTrue);
      controller.mediaEnd();
      await tester.pump();
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(controller.isBackground, isTrue);
      await tester.pump(const Duration(seconds: 10));
      final requestsWhilePaused = liveSite.requestCount;
      final opensWhilePaused = platformPlayer.opened.length;
      await tester.pump(const Duration(seconds: 10));
      final requestsStillPaused = liveSite.requestCount;

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(controller.isBackground, isFalse);
      final requestsAfterResume = liveSite.requestCount;
      final opensAfterResume = platformPlayer.opened.length;
      await tester.pump(const Duration(seconds: 10));

      expect(
        {
          'requestsWhilePaused': requestsWhilePaused,
          'opensWhilePaused': opensWhilePaused,
          'requestsStillPaused': requestsStillPaused,
          'requestsAfterResume': requestsAfterResume,
          'opensAfterResume': opensAfterResume,
          'requestsAfterAnotherCooldown': liveSite.requestCount,
          'jumps': platformPlayer.jumps,
        },
        {
          'requestsWhilePaused': 1,
          'opensWhilePaused': 1,
          'requestsStillPaused': 1,
          'requestsAfterResume': 2,
          'opensAfterResume': 2,
          'requestsAfterAnotherCooldown': 2,
          'jumps': <int>[],
        },
        reason: '自动暂停期间不得重拉或 open，回到前台后只恢复一次排队任务',
      );
    });

    testWidgets('真实刷新等待响应时进入后台不能 open 且回到前台恢复', (tester) async {
      AppSettingsController.instance.playerAutoPause.value = true;
      final liveSite = _BlockedLiveSite();
      final platformPlayer = _RecordingPlatformPlayer();
      final controller = _OfflineLiveRoomController(liveSite, platformPlayer);
      addTearDown(controller.scrollController.dispose);
      addTearDown(controller.player.dispose);
      addTearDown(controller.disposeStream);
      _seedLiveRoom(controller);
      await controller.initPlaylist();
      expect(platformPlayer.opened, hasLength(1));

      final refresh = controller.refreshPlayUrls();
      await liveSite.requested.future;
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      liveSite.response.complete(LivePlayUrl(
        urls: ['https://example.com/late.flv'],
      ));
      await refresh;
      await tester.pump();
      final requestsWhilePaused = liveSite.requestCount;
      final opensWhilePaused = platformPlayer.opened.length;
      await tester.pump(const Duration(seconds: 11));
      final requestsStillPaused = liveSite.requestCount;
      final opensStillPaused = platformPlayer.opened.length;

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      final requestsAfterResume = liveSite.requestCount;
      final opensAfterResume = platformPlayer.opened.length;
      await tester.pump(const Duration(seconds: 10));

      expect(
        {
          'requestsWhilePaused': requestsWhilePaused,
          'opensWhilePaused': opensWhilePaused,
          'requestsStillPaused': requestsStillPaused,
          'opensStillPaused': opensStillPaused,
          'requestsAfterResume': requestsAfterResume,
          'opensAfterResume': opensAfterResume,
          'requestsAfterAnotherCooldown': liveSite.requestCount,
          'jumps': platformPlayer.jumps,
        },
        {
          'requestsWhilePaused': 1,
          'opensWhilePaused': 1,
          'requestsStillPaused': 1,
          'opensStillPaused': 1,
          'requestsAfterResume': 2,
          'opensAfterResume': 2,
          'requestsAfterAnotherCooldown': 2,
          'jumps': <int>[],
        },
        reason: '迟到响应不得在后台重启播放，回到前台后应重新取流恢复一次',
      );
      final resumedPlaylist = platformPlayer.opened.last as Playlist;
      expect(resumedPlaylist.medias.single.uri, 'https://example.com/late.flv');
    });

    testWidgets('冷却重拉失败后下一轮仍自动取流恢复且不重放旧地址', (tester) async {
      final liveSite = _TransientFailureLiveSite();
      final platformPlayer = _RecordingPlatformPlayer();
      final controller = _OfflineLiveRoomController(liveSite, platformPlayer);
      addTearDown(controller.scrollController.dispose);
      addTearDown(controller.player.dispose);
      addTearDown(controller.disposeStream);
      _seedLiveRoom(controller);

      expect(await controller.handleStreamStall(), isTrue);
      expect(liveSite.requestCount, 1);
      expect(platformPlayer.opened, hasLength(1));
      expect(controller.player.state.buffering, isFalse);

      controller.mediaEnd();
      await tester.pump();
      // 不发送新的 EOF 或缓冲信号：第二次取流失败后必须自行继续恢复。
      await tester.pump(const Duration(seconds: 10));
      expect(liveSite.requestCount, 2);
      expect(platformPlayer.opened, hasLength(1));
      expect(platformPlayer.jumps, isEmpty);
      expect(controller.player.state.buffering, isFalse);

      await tester.pump(const Duration(seconds: 10));
      expect(
        {
          'requests': liveSite.requestCount,
          'opens': platformPlayer.opened.length,
          'jumps': platformPlayer.jumps,
        },
        {'requests': 3, 'opens': 2, 'jumps': <int>[]},
        reason: '冷却重拉的临时网络失败不能丢掉恢复任务，也不能回放旧地址',
      );
      final recoveredPlaylist = platformPlayer.opened.last as Playlist;
      expect(recoveredPlaylist.medias.single.uri,
          'https://example.com/fresh-3.flv');
      controller.disposeStream();
      await tester.pump(const Duration(seconds: 11));
      expect(liveSite.requestCount, 3);
    });

    for (final event in ['mediaEnd', 'mediaError']) {
      testWidgets('$event 等待真实取流期间销毁后不得继续 jump 或 open', (tester) async {
        final liveSite = _BlockedLiveSite();
        final platformPlayer = _RecordingPlatformPlayer();
        final controller = _OfflineLiveRoomController(liveSite, platformPlayer);
        addTearDown(controller.scrollController.dispose);
        addTearDown(controller.player.dispose);
        addTearDown(controller.disposeStream);
        _seedLiveRoom(controller);
        await controller.initPlaylist();
        expect(platformPlayer.opened, hasLength(1));

        if (event == 'mediaEnd') {
          controller.mediaEnd();
        } else {
          controller.mediaError('offline stream error');
        }
        await tester.pump();
        try {
          expect(liveSite.requested.isCompleted, isTrue);
          expect(liveSite.requestCount, 1);
          expect(liveSite.response.isCompleted, isFalse);
        } finally {
          // 销毁发生在真实媒体回调 await handleStreamStall 尚未返回时。
          controller.disposeStream();
          liveSite.response.complete(LivePlayUrl(
            urls: ['https://example.com/late.flv'],
          ));
          await tester.pump();
        }

        expect(platformPlayer.opened, hasLength(1),
            reason: '$event 的迟到响应不得在销毁后再次 open');
        expect(platformPlayer.jumps, isEmpty,
            reason: '$event 不能在销毁后因刷新返回 false 而继续 setPlayer/jump');
        await tester.pump(const Duration(seconds: 11));
        expect(liveSite.requestCount, 1);
        expect(platformPlayer.opened, hasLength(1));
        expect(platformPlayer.jumps, isEmpty);
      });

      test('$event 在真实 refreshPlayUrls 等待站点响应时不重放旧地址', () async {
        final liveSite = _BlockedLiveSite();
        final platformPlayer = _RecordingPlatformPlayer();
        final controller = _OfflineLiveRoomController(liveSite, platformPlayer);
        addTearDown(controller.scrollController.dispose);
        addTearDown(controller.player.dispose);
        addTearDown(controller.disposeStream);
        _seedLiveRoom(controller);

        // 先装入旧地址，随后保留真实 refreshPlayUrls -> getPlayUrls 调用链。
        await controller.initPlaylist();
        expect(platformPlayer.opened, hasLength(1));
        final refresh = controller.refreshPlayUrls();
        await liveSite.requested.future;
        try {
          expect(liveSite.requestCount, 1);
          expect(liveSite.requestDetail, same(controller.detail.value));
          expect(liveSite.requestQuality, same(controller.qualites[0]));
          expect(liveSite.response.isCompleted, isFalse);

          if (event == 'mediaEnd') {
            controller.mediaEnd();
          } else {
            controller.mediaError('offline stream error');
          }
          // 媒体回调为 async void；排空其 await handleStreamStall 后的续体。
          await Future<void>.delayed(Duration.zero);

          expect(liveSite.response.isCompleted, isFalse);
          expect(liveSite.requestCount, 1);
          expect(platformPlayer.opened, hasLength(1));
          expect(
            platformPlayer.jumps,
            isEmpty,
            reason: '$event 不应经 setPlayer/jump 重放仍在等待替换的旧地址',
          );
        } finally {
          // 即使红灯也释放阻塞，等待真实 initPlaylist/open 完成后再清理。
          liveSite.response.complete(LivePlayUrl(
            urls: ['https://example.com/fresh.flv'],
          ));
          expect(await refresh, isTrue);
          expect(platformPlayer.opened, hasLength(2));
          final refreshedPlaylist = platformPlayer.opened.last as Playlist;
          expect(refreshedPlaylist.medias.single.uri,
              'https://example.com/fresh.flv');
        }
      });
    }
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

// 构造本身不依赖存储；只跳过 Get.put 自动触发的本地配置读取。
class _OfflineAppSettingsController extends AppSettingsController {
  @override
  // 故意不调用生产 onInit，避免访问 LocalStorageService。
  // ignore: must_call_super
  void onInit() {}
}

class _BlockedLiveSite extends LiveSite {
  final requested = Completer<void>();
  final response = Completer<LivePlayUrl>();
  var requestCount = 0;
  LiveRoomDetail? requestDetail;
  LivePlayQuality? requestQuality;

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    requestCount += 1;
    requestDetail = detail;
    requestQuality = quality;
    if (!requested.isCompleted) requested.complete();
    return response.future;
  }
}

class _TransientFailureLiveSite extends LiveSite {
  var requestCount = 0;

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    requestCount += 1;
    if (requestCount == 2) {
      throw StateError('offline temporary refresh failure');
    }
    return LivePlayUrl(
      urls: ['https://example.com/fresh-$requestCount.flv'],
    );
  }
}

class _RecordingPlatformPlayer extends PlatformPlayer {
  _RecordingPlatformPlayer()
      : super(configuration: const PlayerConfiguration());

  final opened = <Playable>[];
  final jumps = <int>[];

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable);
  }

  @override
  Future<void> jump(int index) async {
    jumps.add(index);
  }
}

class _OfflineLiveRoomController extends LiveRoomController {
  _OfflineLiveRoomController(LiveSite liveSite, PlatformPlayer platformPlayer)
      : _player = Player(platformPlayer: platformPlayer),
        super(
          pSite: Site(id: 'douyu', liveSite: liveSite, logo: '', name: '斗鱼直播'),
          pRoomId: '123',
        );

  final Player _player;

  @override
  Player get player => _player;

  // 生产实现需要 NativePlayer；测试只替换原生配置边界。
  @override
  Future<void> initializePlayer() async {}
}

void _seedLiveRoom(LiveRoomController controller) {
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
    url: 'https://example.com/room/123',
  );
  controller.liveStatus.value = true;
  controller.qualites.add(LivePlayQuality(quality: '原画', data: null));
  controller.currentQuality = 0;
  controller.playUrls.add('https://example.com/old.flv');
  controller.currentLineIndex = 0;
}
