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
}