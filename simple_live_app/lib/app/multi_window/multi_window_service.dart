import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
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

  /// 主窗口注册数据服务处理器，响应子窗口的数据请求
  ///
  /// 子窗口（ChildLocalStorageService/ChildDBService）不能自己打开 Hive box：
  /// 与主窗口同进程，Hive 的 .lock 独占文件锁在 Windows 上按句柄判定冲突，
  /// 第二个 engine 加锁会永久阻塞。因此数据全部由主窗口读写、子窗口转发。
  Future<void> registerMainWindowHandler() async {
    if (isChildWindow) return;
    final controller = WindowController.fromWindowId(windowId);
    await controller.setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'mw_snapshot':
          return {
            'settings':
                LocalStorageService.instance.settingsBox.toMap(),
            'shield':
                LocalStorageService.instance.shieldBox.values.toList(),
            'follows': DBService.instance.followBox.values
                .map((e) => e.toJson())
                .toList(),
            'tags': DBService.instance.tagBox.values
                .map((e) => e.toJson())
                .toList(),
            'histories': DBService.instance.historyBox.values
                .map((e) => e.toJson())
                .toList(),
          };
        case 'mw_set_value':
          final args = Map<dynamic, dynamic>.from(call.arguments as Map);
          await LocalStorageService.instance
              .setValue(args['key'], args['value']);
          return true;
        case 'mw_remove_value':
          await LocalStorageService.instance.removeValue(call.arguments);
          return true;
        case 'mw_shield_add':
          await LocalStorageService.instance.addShield(call.arguments);
          AppSettingsController.instance.shieldList.add(call.arguments);
          return true;
        case 'mw_shield_remove':
          await LocalStorageService.instance.removeShield(call.arguments);
          AppSettingsController.instance.shieldList.remove(call.arguments);
          return true;
        case 'mw_shield_clear':
          await LocalStorageService.instance.clearShield();
          AppSettingsController.instance.shieldList.clear();
          return true;
        case 'mw_add_follow':
          await DBService.instance.addFollow(FollowUser.fromJson(
              Map<String, dynamic>.from(call.arguments as Map)));
          // 通知主窗口关注页刷新
          EventBus.instance.emit(Constant.kUpdateFollow, null);
          return true;
        case 'mw_delete_follow':
          await DBService.instance.deleteFollow(call.arguments as String);
          EventBus.instance.emit(Constant.kUpdateFollow, null);
          return true;
        case 'mw_add_history':
          await DBService.instance.addOrUpdateHistory(History.fromJson(
              Map<String, dynamic>.from(call.arguments as Map)));
          return true;
        case 'mw_add_follow_tag':
        case 'mw_update_follow_tag':
          // 子窗口已生成好 id，主窗口直接落盘
          await DBService.instance.updateFollowTag(FollowUserTag.fromJson(
              Map<String, dynamic>.from(call.arguments as Map)));
          return true;
        case 'mw_delete_follow_tag':
          await DBService.instance.deleteFollowTag(call.arguments as String);
          return true;
        default:
          throw MissingPluginException('Not implemented: ${call.method}');
      }
    });
  }

  /// 打开直播间：已开则聚焦，否则新建
  Future<void> openRoom({
    required Site site,
    required String roomId,
    String title = '',
  }) async {
    try {
      final args = WindowArgs(siteId: site.id, roomId: roomId, title: title);
      // 诊断 Windows 子窗口卡死：确保日志写文件（排查后可移除）
      if (Log.logFileWriter == null) Log.initWriter();
      Log.logPrint('[MW] openRoom begin: ${site.id}/$roomId');
      final windows = await WindowController.getAll();
      for (final controller in windows) {
        final existing = WindowArgs.decode(controller.arguments);
        if (existing.siteId == args.siteId && existing.roomId == args.roomId) {
          // 主窗口的 siteId 为空，天然不匹配，无需额外排除
          await controller.center();
          return;
        }
      }
      Log.logPrint('[MW] openRoom: creating child window');
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: args.encode(),
          hiddenAtLaunch: true,
        ),
      );
      // 原生 Create 失败时返回空字符串（release 下 assert 被移除），
      // 表现为点了没反应，必须显式记录
      if (controller.windowId.isEmpty) {
        Log.logPrint('[MW] openRoom FAILED: native createWindow returned empty id');
      } else {
        Log.logPrint('[MW] openRoom: child window created id=${controller.windowId}');
      }
    } catch (e) {
      Log.logPrint('[MW] 打开新窗口失败: $e');
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
      Log.logPrint('[MW] child: setupSelfWindow waiting native view');
      if (!await _waitForNativeView()) {
        Log.logPrint('[MW] child: 子窗口视图未就绪，跳过窗口设置');
        return;
      }
      Log.logPrint('[MW] child: native view ready, set size/title/show');
      final size =
          _childWindowSize[windowArgs.siteId] ?? _defaultChildWindowSize;
      await windowManager.setSize(size);
      await windowManager.center();
      final title = windowArgs.title.isEmpty
          ? 'Simple Live'
          : '${windowArgs.title} - Simple Live';
      await windowManager.setTitle(title);
      await windowManager.show();
      Log.logPrint('[MW] child: window shown');
    } catch (e) {
      Log.logPrint('[MW] child: 子窗口初始化失败: $e');
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