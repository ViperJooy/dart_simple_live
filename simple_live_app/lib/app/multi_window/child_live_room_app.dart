import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/child_data_services.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';
import 'package:window_manager/window_manager.dart';

/// 子窗口的精简服务栈
///
/// 与 main.dart 的 initServices() 的区别：
/// 1. **不注册 SyncService**。SyncService.onInit 会无条件 UDP.bind(23235)
///    与 shelf serve 23234，第二个窗口必然抛 SocketException(address already in use)。
/// 2. **LocalStorageService/DBService 用子窗口版本**（ChildLocalStorageService/
///    ChildDBService）。子窗口与主窗口同进程，Hive openBox 的 .lock 独占文件锁
///    在 Windows 上按句柄判定冲突（macOS fcntl 按进程判定所以没事），
///    第二个 engine 再开同一个 box 会永久阻塞 —— 表现为点开直播间卡死。
///    子窗口改为从主窗口拉数据快照，写操作转发给主窗口落盘。
///
/// 其余服务都是播放页必需的：关注状态走 FollowService/DBService，
/// 历史写入走 DBService，B 站高画质走 BiliBiliAccountService，
/// 主题与播放器参数走 AppSettingsController。
Future<void> initChildServices() async {
  Utils.packageInfo = await PackageInfo.fromPlatform();
  Log.d("Init LocalStorage Service (child window)");

  // 数据全部经由主窗口转发（主窗口独占 Hive box 的文件锁）
  final mainWindow = await findMainWindowController();
  final snapshot = await fetchMainWindowSnapshot(mainWindow);
  Log.logPrint('[MW] child: main window snapshot ready');
  await Get.put<LocalStorageService>(
          ChildLocalStorageService(mainWindow, snapshot))
      .init();
  await Get.put<DBService>(ChildDBService(mainWindow, snapshot)).init();

  Get.put(AppSettingsController());
  Get.put(BiliBiliAccountService());
  Get.put(DouyinAccountService());
  Get.put(FollowService());

  initCoreLog();
}

/// 子窗口应用
///
/// 播放页直接作为根页面，同时保留 AppPages.routes 以便弹幕设置、
/// 播放设置等子页面能正常 push。
class ChildLiveRoomApp extends StatefulWidget {
  const ChildLiveRoomApp({super.key});

  @override
  State<ChildLiveRoomApp> createState() => _ChildLiveRoomAppState();
}

class _ChildLiveRoomAppState extends State<ChildLiveRoomApp>
    with WindowListener {
  bool _closing = false;
  bool _controllerReady = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // 拦截关闭，先回收播放器再真正关窗
    windowManager.setPreventClose(true);
    // LiveRoomController 在首帧后由 main.dart 创建，这里等它就位后再挂页面
    _waitForController();
  }

  /// 等待 LiveRoomController 注册完成后再构建播放页
  ///
  /// 控制器必须在 FlutterSmartDialog.init 的 builder 跑过之后才能创建，
  /// 否则它 onInit 里的 SmartDialog.showLoading 会触发
  /// LateInitializationError(loadingWidget)，表现为加载失败需手动刷新。
  void _waitForController() {
    if (Get.isRegistered<LiveRoomController>()) {
      _controllerReady = true;
      return;
    }
    Future.delayed(const Duration(milliseconds: 16), () {
      if (!mounted) return;
      if (Get.isRegistered<LiveRoomController>()) {
        setState(() => _controllerReady = true);
        return;
      }
      _waitForController();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    // 窗口销毁时 engine 会直接结束，GetX 的 onClose 不保证执行，
    // 必须在此显式回收播放器，否则 Windows 上 mpv 线程与纹理注销竞争会闪退
    if (Get.isRegistered<LiveRoomController>()) {
      await Get.find<LiveRoomController>().teardown();
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    final styleColor = Color(AppSettingsController.instance.styleColor.value);
    return GetMaterialApp(
      title: 'Simple Live',
      theme: AppStyle.lightTheme
          .copyWith(colorScheme: ColorScheme.fromSeed(seedColor: styleColor)),
      darkTheme: AppStyle.darkTheme.copyWith(
        colorScheme: ColorScheme.fromSeed(
            seedColor: styleColor, brightness: Brightness.dark),
      ),
      themeMode:
          ThemeMode.values[Get.find<AppSettingsController>().themeMode.value],
      getPages: AppPages.routes,
      home: _controllerReady
          ? const LiveRoomPage()
          // 控制器尚未就绪时的占位页
          : const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
      locale: const Locale("zh", "CN"),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale("zh", "CN")],
      navigatorObservers: [FlutterSmartDialog.observer],
      builder: FlutterSmartDialog.init(
        loadingBuilder: ((msg) => const AppLoaddingWidget()),
        //字体大小不跟随系统变化
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.0)),
          child: child!,
        ),
      ),
    );
  }
}