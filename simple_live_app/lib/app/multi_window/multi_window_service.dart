import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:window_manager/window_manager.dart';

/// 子窗口尺寸
/// - 抖音竖屏，其余横屏。不依赖播放状态，保证首帧即可确定。
const _childWindowSize = {
  'douyin': Size(480, 854),
};
const _defaultChildWindowSize = Size(854, 480);

/// 多窗口服务
///
/// 每个窗口（engine/isolate）各持有一个实例，主窗口与子窗口各一个。
/// 主窗口用 [openRoom] 创建子窗口；子窗口控制自己。
class MultiWindowService extends GetxService {
  final String windowId;
  final WindowArgs windowArgs;

  MultiWindowService({
    required this.windowId,
    required this.windowArgs,
  });

  bool get isChildWindow => !windowArgs.isMainWindow;

  /// 打开直播间：已开则聚焦，否则新建
  Future<void> openRoom({
    required Site site,
    required String roomId,
    String title = '',
  }) async {
    try {
      final args = WindowArgs(siteId: site.id, roomId: roomId, title: title);
      final windows = await WindowController.getAll();
      for (final controller in windows) {
        final existing = WindowArgs.decode(controller.arguments);
        if (existing.siteId == args.siteId && existing.roomId == args.roomId) {
          // 主窗口的 siteId 为空，天然不匹配，无需额外排除
          await controller.center();
          return;
        }
      }
      await WindowController.create(
        WindowConfiguration(
          arguments: args.encode(),
          hiddenAtLaunch: true,
        ),
      );
    } catch (e) {
      Log.logPrint('打开新窗口失败: $e');
    }
  }

  /// 子窗口设置自己的窗口属性并显示
  ///
  /// WindowConfiguration 没有尺寸字段，只能由子窗口自行设置。
  ///
  /// 必须等原生视图挂到 NSWindow 之后再调用 window_manager：它的 macOS 实现
  /// 用 `registrar.view?.window!` 强解包，视图未就绪时会 nil 解包崩溃
  /// （SIGTRAP，Unexpectedly found nil）。
  /// Dart 首帧并不代表原生视图已挂载，所以这里轮询重试。
  Future<void> setupSelfWindow() async {
    if (!isChildWindow) return;
    try {
      if (!await _waitForNativeView()) {
        Log.logPrint('子窗口视图未就绪，跳过窗口设置');
        return;
      }
      final size =
          _childWindowSize[windowArgs.siteId] ?? _defaultChildWindowSize;
      await windowManager.setSize(size);
      await windowManager.center();
      final title = windowArgs.title.isEmpty
          ? 'Simple Live'
          : '${windowArgs.title} - Simple Live';
      await windowManager.setTitle(title);
      await windowManager.show();
    } catch (e) {
      Log.logPrint('子窗口初始化失败: $e');
    }
  }

  /// 轮询等待 window_manager 能够解析到原生窗口
  ///
  /// window_manager 的 macOS 实现在视图未挂载时 `registrar.view?.window!`
  /// 会崩溃，无法用 try/catch 捕获，只能靠成功调用来探测就绪状态。
  /// isFocused() 是副作用最小的探测方式。
  Future<bool> _waitForNativeView() async {
    const maxAttempts = 40;
    const interval = Duration(milliseconds: 100);
    for (var i = 0; i < maxAttempts; i++) {
      try {
        await windowManager.isFocused();
        return true;
      } catch (e) {
        await Future.delayed(interval);
      }
    }
    return false;
  }

  /// 注册本窗口的方法处理器，供其他窗口通过 WindowController 扩展调用
  Future<void> registerChildWindowHandler() async {
    if (!isChildWindow) return;
    final controller = WindowController.fromWindowId(windowId);
    await controller.setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'window_center':
          await windowManager.center();
          return true;
        case 'window_close':
          await windowManager.close();
          return true;
        default:
          throw MissingPluginException('Not implemented: ${call.method}');
      }
    });
  }

  /// 关闭本窗口
  ///
  /// 主窗口不支持关闭自身（关闭主窗口 = 退出应用，由原生层处理），故直接返回。
  Future<void> closeSelf() async {
    if (!isChildWindow) return;
    await WindowController.fromWindowId(windowId).closeSelfWindow();
  }
}

/// WindowController 扩展：把对子窗口的操作转发到子窗口自己的 engine 执行
///
/// window_manager 0.5.1 按 engine 解析窗口句柄，所以这些方法只影响目标子窗口。
extension WindowControllerExtension on WindowController {
  /// 聚焦窗口
  Future<void> center() => invokeMethod('window_center');

  /// 关闭窗口
  Future<void> closeSelfWindow() => invokeMethod('window_close');
}