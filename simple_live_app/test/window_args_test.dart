import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';

void main() {
  group('WindowArgs.encode', () {
    test('不含 title 时只编码 siteId 与 roomId', () {
      const args = WindowArgs(siteId: 'douyu', roomId: '9999');
      expect(args.encode(), 'siteId=douyu&roomId=9999');
    });

    test('title 经过 URI 编码', () {
      const args =
          WindowArgs(siteId: 'huya', roomId: '123', title: '测试 主播 & 房');
      // Uri.encodeQueryComponent 把空格编码为 +，& 编码为 %26
      expect(args.encode(),
          'siteId=huya&roomId=123&title=%E6%B5%8B%E8%AF%95+%E4%B8%BB%E6%92%AD+%26+%E6%88%BF');
    });

    test('title 为空字符串时不输出 title 字段', () {
      const args = WindowArgs(siteId: 'douyu', roomId: '1', title: '');
      expect(args.encode(), 'siteId=douyu&roomId=1');
    });
  });

  group('WindowArgs.decode', () {
    test('解析完整的 encode 输出（round trip）', () {
      const original = WindowArgs(siteId: 'douyu', roomId: '9999', title: '主播A');
      final decoded = WindowArgs.decode(original.encode());
      expect(decoded.siteId, 'douyu');
      expect(decoded.roomId, '9999');
      expect(decoded.title, '主播A');
    });

    test('空字符串解析为主窗口', () {
      final args = WindowArgs.decode('');
      expect(args.isMainWindow, isTrue);
      expect(args.roomId, '');
    });

    test('缺少 roomId 时 roomId 为空字符串', () {
      final args = WindowArgs.decode('siteId=douyu');
      expect(args.siteId, 'douyu');
      expect(args.roomId, '');
    });

    test('未知的额外字段被忽略', () {
      final args = WindowArgs.decode('siteId=douyu&roomId=1&foo=bar');
      expect(args.siteId, 'douyu');
      expect(args.roomId, '1');
    });
  });

  group('isMainWindow', () {
    test('siteId 为空即主窗口', () {
      expect(const WindowArgs(siteId: '', roomId: '1').isMainWindow, isTrue);
    });

    test('siteId 非空即子窗口', () {
      expect(
          const WindowArgs(siteId: 'douyu', roomId: '1').isMainWindow, isFalse);
    });
  });

  group('isMultiWindowPlatform', () {
    test('当前运行平台的值与 Platform 实际一致', () {
      expect(isMultiWindowPlatform, Platform.isWindows || Platform.isMacOS);
    });
  });

  group('子窗口关闭时回收播放器', () {
    test('teardown 幂等，且 stop 排在 dispose 之前', () {
      final source = File(
        'lib/modules/live_room/player/player_controller.dart',
      ).readAsStringSync();
      expect(source, contains('Future<void> teardown()'));
      expect(source, contains('_tornDown'));
      final stop = source.indexOf('await player.stop()');
      final dispose = source.indexOf('await player.dispose()');
      expect(stop, greaterThan(-1));
      expect(dispose, greaterThan(-1));
      // stop 必须排在 dispose 之前，否则 Windows 上 0xc0000005 闪退
      expect(stop, lessThan(dispose));
    });

    test('子窗口拦截窗口关闭，先回收再关窗', () {
      final source = File(
        'lib/app/multi_window/child_live_room_app.dart',
      ).readAsStringSync();
      expect(source, contains('WindowListener'));
      expect(source, contains('onWindowClose'));
      expect(source, contains('setPreventClose(true)'));
      final teardown = source.indexOf('.teardown()');
      final close = source.indexOf('windowManager.close()');
      expect(teardown, greaterThan(-1));
      expect(close, greaterThan(-1));
      // 先回收播放器再关窗，否则 engine 销毁时 mpv 线程与纹理注销竞争会闪退
      expect(teardown, lessThan(close));
    });
  });

  group('子窗口不终止整个进程', () {
    test('live_room_controller 不再直接调用 dart:io 的 exit', () {
      final source = File(
        'lib/modules/live_room/live_room_controller.dart',
      ).readAsStringSync();
      // exit(0) 解析到 dart:io 的 exit，多开下任一子窗口定时器到期会杀掉全进程
      final withoutComments = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(withoutComments.contains('exit(0)'), isFalse);
      expect(source, contains('closeSelf()'));
    });
  });

  group('音量按窗口隔离', () {
    test('子窗口音量不写回全局设置', () {
      final source = File(
        'lib/modules/live_room/player/player_controller.dart',
      ).readAsStringSync();
      expect(source, contains('isIndependentVolume'));
      expect(source, contains('currentVolume'));
      // 持久化必须被 isIndependentVolume 守卫，否则子窗口 A 调音量会
      // 连带改掉主窗口与子窗口 B 的音量，并落盘影响下次启动
      expect(source, contains('if (!isIndependentVolume)'));
    });
  });

  group('toLiveRoomDetail 平台隔离', () {
    test('桌面端分支被平台判定包住，移动端路径保留', () {
      final source =
          File('lib/routes/app_navigation.dart').readAsStringSync();
      expect(source, contains('isMultiWindowPlatform'));
      expect(source, contains('RoutePath.kLiveRoomDetail'));
      expect(source, contains('MultiWindowService'));
      // 移动端原有的 Get.toNamed 必须保留，不能被桌面分支替换掉
      expect(source, contains('Get.toNamed(RoutePath.kLiveRoomDetail'));
    });
  });

  group('子窗口服务栈', () {
    test('initChildServices 的实现不注册 SyncService', () {
      final source = File(
        'lib/app/multi_window/child_live_room_app.dart',
      ).readAsStringSync();
      expect(source, contains('initChildServices'));
      // SyncService.onInit 会无条件绑定 UDP 23235 与 HTTP 23234，
      // 第二个窗口必然 SocketException，子窗口不得初始化它。
      // 注释里提到 SyncService 是允许的，注册代码里出现不允许。
      final withoutComments = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(withoutComments.contains('SyncService'), isFalse);
    });
  });

  group('断流重试串行化', () {
    String readController() =>
        File('lib/modules/live_room/live_room_controller.dart').readAsStringSync();

    test('刷新播放地址有互斥保护，且不会在 open 完成前解锁', () {
      final source = readController();
      // player.open 是异步的，若在 finally 里立刻解锁 _refreshingPlayUrls，
      // mediaEnd/mediaError/缓冲看门狗三个触发源会并发拉流并各自 open，
      // 把 mpv playlist 状态搅乱，表现为播放几分钟后卡死且不报错。
      expect(source, contains('_refreshingPlayUrls'));
      // 解锁必须发生在确认 open 完成之后，而不是 open 调用之前的 finally。
      // initPlaylist 内部 await player.open，所以 await initPlaylist() 必须
      // 排在解锁之前，且必须是 await（不 await 就等于没等）。
      final refreshIdx = source.indexOf('Future<bool> refreshPlayUrls()');
      expect(refreshIdx, greaterThan(-1));
      final body = source.substring(refreshIdx, refreshIdx + 2000);
      final awaitInit = body.indexOf('await initPlaylist()');
      final unlock = body.indexOf('_refreshingPlayUrls = false');
      expect(awaitInit, greaterThan(-1));
      expect(unlock, greaterThan(-1));
      // await initPlaylist 必须排在解锁之前
      expect(awaitInit, lessThan(unlock));

      // initPlaylist 本身必须真的 await player.open，否则等待没有意义
      final initIdx = source.indexOf('Future<void> initPlaylist()');
      expect(initIdx, greaterThan(-1));
      final initBody = source.substring(initIdx, initIdx + 1500);
      expect(initBody, contains('await player.open'));
    });

    test('所有断流触发源都经过同一个串行化入口', () {
      final source = readController();
      // mediaEnd / mediaError / 缓冲看门狗 三个来源必须汇聚到同一方法，
      // 而不是各自直接调 refreshPlayUrls。
      expect(source.contains('await handleStreamStall()'), isTrue);
      final directCalls = 'refreshPlayUrls();'.allMatches(source).length;
      // 只允许在串行化入口内部自调用一次，其他地方必须走 handleStreamStall
      expect(directCalls, lessThanOrEqualTo(1));
    });

    test('重试有冷却时间，避免签名刚过期时疯狂重拉', () {
      final source = readController();
      // 斗鱼签名 expire=300，但 CDN 可能在签名到期前几分钟就掐断，
      // 没有冷却会导致连续 open 把播放器状态搅乱
      expect(source, contains('_retryCooldownTimer'));
      expect(source, contains('_retryCooldown'));
    });

    test('切线路不会与其他重试并发', () {
      final source = readController();
      // changePlayLine 也会触发 jump/open，必须纳入同一把锁
      final idx = source.indexOf('changePlayLine(int index)');
      expect(idx, greaterThan(-1));
      final body = source.substring(idx, idx + 400);
      expect(body, contains('_refreshingPlayUrls'));
    });
  });
}