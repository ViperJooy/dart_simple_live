import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/child_data_services.dart';
import 'package:simple_live_app/app/multi_window/child_live_room_app.dart';
import 'package:simple_live_app/app/multi_window/multi_window_service.dart';
import 'package:simple_live_app/app/multi_window/room_process.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/listen_fourth_button.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/other/debug_log_page.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';
import 'package:window_manager/window_manager.dart';

import 'package:path/path.dart' as p;
import 'package:dynamic_color/dynamic_color.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Windows 房间进程模式：simple_live_app.exe --room <siteId> <roomId> <快照文件>
  // 每个直播间一个独立进程（同进程多 engine 在这台机器上输入路由会坏，
  // 见 room_process.dart 头部注释）
  final roomArgs = RoomProcessArgs.tryParse(args);
  if (roomArgs != null) {
    try {
      await runRoomProcess(roomArgs);
    } catch (e) {
      // 窗口初始隐藏，启动失败不能静默挂住一个隐形进程
      Log.logPrint('[RoomProc] 启动失败: $e');
      exit(1);
    }
    return;
  }

  // 子窗口由 desktop_multi_window 以独立 engine 启动，启动参数里带直播间信息。
  // 主窗口也要注册 MultiWindowService，因为 AppNavigator.toLiveRoomDetail
  // 在桌面端要用它开新窗口。
  if (isMultiWindowPlatform) {
    final controller = await WindowController.fromCurrentEngine();
    final windowArgs = WindowArgs.decode(controller.arguments);
    Get.put(MultiWindowService(
      windowId: controller.windowId,
      windowArgs: windowArgs,
    ));
    if (!windowArgs.isMainWindow) {
      await runChildWindow();
      return;
    }
    // 主窗口：为子窗口提供数据转发服务。
    // Hive box 被主窗口独占加锁，子窗口（同进程另一 engine）不能再打开，
    // 其读写请求全部通过窗口通道转发到这里执行。
    Get.find<MultiWindowService>().registerMainWindowHandler();

    // 诊断：主窗口框架层探针（排查多窗口下主窗口点击失灵，排查后可移除）
    // 1. pointerRouter 全局路由：框架层收到的每一次 pointer down
    //    （绕过 hit-test 吸收，SmartDialog 遮罩也挡不住）
    GestureBinding.instance.pointerRouter.addGlobalRoute((PointerEvent event) {
      if (event is PointerDownEvent) {
        Log.logPrint('[MW] main: framework pointer down ${event.position}');
      }
    });
    // 2. 帧产出探针：每 3 秒主动排一帧，帧没产出来就说明 UI 线程停了
    Timer.periodic(const Duration(seconds: 3), (_) {
      WidgetsBinding.instance.scheduleFrame();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Log.logPrint('[MW] main: frame rendered');
      });
    });
  }

  await migrateData();
  await initWindow();
  MediaKit.ensureInitialized();
  await Hive.initFlutter(
    (!Platform.isAndroid && !Platform.isIOS)
        ? (await getApplicationSupportDirectory()).path
        : null,
  );
  //初始化服务
  await initServices();
  // Windows 主窗口进程：轮询应用房间进程投递的写操作（关注/历史/设置落盘）
  if (Platform.isWindows) {
    RoomProcessStore.cleanupOldSnapshots();
    RoomProcessStore.startWriteApplier();
  }
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  //设置状态栏为透明
  SystemUiOverlayStyle systemUiOverlayStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
  );
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyle);
  runApp(const MyApp());
}

/// 子窗口入口
Future<void> runChildWindow() async {
  final service = Get.find<MultiWindowService>();
  final windowArgs = service.windowArgs;

  // 诊断 Windows 子窗口卡死：确保日志写文件（排查后可移除）
  if (Log.logFileWriter == null) Log.initWriter();
  Log.logPrint('[MW] child: engine started args=${windowArgs.encode()}');
  MediaKit.ensureInitialized();
  // 子窗口不能 Hive.openBox（.lock 文件锁被主窗口独占），
  // 数据从主窗口拉快照，写操作经窗口通道转发给主窗口落盘
  final mainWindow = await findMainWindowController();
  final snapshot = await fetchMainWindowSnapshot(mainWindow);
  Log.logPrint('[MW] child: main window snapshot ready');
  await initChildServices(
    snapshot: snapshot,
    invoker: (method, [args]) => mainWindow.invokeMethod(method, args),
  );
  Log.logPrint('[MW] child: services ready');
  await windowManager.ensureInitialized();
  await service.registerChildWindowHandler();
  Log.logPrint('[MW] child: windowManager ready, runApp');

  runApp(const ChildLiveRoomApp());

  // LiveRoomController 的 onInit 会同步调用 loadData()，里面用了
  // SmartDialog.showLoading。它依赖 FlutterSmartDialog.init 的 builder 跑过之后
  // DialogProxy.initialize() 才会初始化 loadingWidget（late 字段）。
  // 若在 runApp 之前 Get.put，首次 showLoading 就会抛
  // LateInitializationError: Field 'loadingWidget' has not been initialized，
  // 表现为「直播间加载失败」，必须手动刷新才恢复。
  // 所以把控制器推迟到 childApp 的首帧之后再创建，
  // 由 ChildLiveRoomApp 内部的占位页等待并重建。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Log.logPrint('[MW] child: first frame, creating LiveRoomController');
    Get.put<LiveRoomController>(LiveRoomController(
      pSite: Sites.allSites[windowArgs.siteId]!,
      pRoomId: windowArgs.roomId,
    ));
  });

  // 等原生视图挂到窗口后再设置窗口属性并显示。
  // Dart 首帧不代表 NSWindow 已就绪，过早调用 window_manager 会 nil 解包崩溃。
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await service.setupSelfWindow();
  });
}

/// 将Hive数据迁移到Application Support
Future migrateData() async {
  if (Platform.isAndroid || Platform.isIOS) {
    return;
  }
  var hiveFileList = [
    "followuser",
    //旧版本写错成hostiry了
    "hostiry",
    "followusertag",
    "localstorage",
    "danmushield",
  ];
  try {
    var newDir = await getApplicationSupportDirectory();
    var hiveFile = File(p.join(newDir.path, "followuser.hive"));
    if (await hiveFile.exists()) {
      return;
    }

    var oldDir = await getApplicationDocumentsDirectory();
    for (var element in hiveFileList) {
      var oldFile = File(p.join(oldDir.path, "$element.hive"));
      if (await oldFile.exists()) {
        var fileName = "$element.hive";
        if (element == "hostiry") {
          fileName = "history.hive";
        }
        await oldFile.copy(p.join(newDir.path, fileName));
        await oldFile.delete();
      }
      var lockFile = File(p.join(oldDir.path, "$element.lock"));
      if (await lockFile.exists()) {
        await lockFile.delete();
      }
    }
  } catch (e) {
    Log.logPrint(e);
  }
}

Future initWindow() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    minimumSize: Size(280, 280),
    center: true,
    title: "Simple Live",
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

Future initServices() async {
  Hive.registerAdapter(FollowUserAdapter());
  Hive.registerAdapter(HistoryAdapter());
  Hive.registerAdapter(FollowUserTagAdapter());

  //包信息
  Utils.packageInfo = await PackageInfo.fromPlatform();
  //本地存储
  Log.d("Init LocalStorage Service");
  await Get.put(LocalStorageService()).init();
  await Get.put(DBService()).init();
  //初始化设置控制器
  Get.put(AppSettingsController());

  Get.put(BiliBiliAccountService());

  Get.put(DouyinAccountService());

  Get.put(SyncService());

  Get.put(FollowService());

  initCoreLog();
}



class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    bool isDynamicColor = AppSettingsController.instance.isDynamic.value;
    Color styleColor = Color(AppSettingsController.instance.styleColor.value);
    return DynamicColorBuilder(
        builder: ((ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
      ColorScheme? lightColorScheme;
      ColorScheme? darkColorScheme;
      if (lightDynamic != null && darkDynamic != null && isDynamicColor) {
        lightColorScheme = lightDynamic;
        darkColorScheme = darkDynamic;
      } else {
        lightColorScheme = ColorScheme.fromSeed(
          seedColor: styleColor,
          brightness: Brightness.light,
        );
        darkColorScheme = ColorScheme.fromSeed(
            seedColor: styleColor, brightness: Brightness.dark);
      }
      return GetMaterialApp(
        title: "Simple Live",
        theme: AppStyle.lightTheme.copyWith(colorScheme: lightColorScheme),
        darkTheme: AppStyle.darkTheme.copyWith(colorScheme: darkColorScheme),
        themeMode:
            ThemeMode.values[Get.find<AppSettingsController>().themeMode.value],
        initialRoute: RoutePath.kIndex,
        getPages: AppPages.routes,
        //国际化
        locale: const Locale("zh", "CN"),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale("zh", "CN")],
        logWriterCallback: (text, {bool? isError}) {
          Log.addDebugLog(text, (isError ?? false) ? Colors.red : Colors.grey);
          Log.writeLog(text, (isError ?? false) ? Level.error : Level.info);
        },
        // 升级后Android页面过渡动画似乎有BUG
        defaultTransition: Platform.isAndroid ? Transition.cupertino : null,
        //debugShowCheckedModeBanner: false,
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(
          loadingBuilder: ((msg) => const AppLoaddingWidget()),
          //字体大小不跟随系统变化
          builder: (context, child) {
            // Fix for HyperOS windowed-mode Flutter bug:
            // - Values > 50 indicate the bug (windowed mode on HyperOS)
            // - Values == 0 are valid for fullscreen/immersive mode and must NOT be treated as abnormal
            const fallbackPadding = EdgeInsets.only(top: 25, bottom: 35);
            const maxNormalPadding = 50.0;

            final mediaQueryData = MediaQuery.of(context);
            final hasAbnormalPadding = mediaQueryData.viewPadding.top > maxNormalPadding;

            final fixedMediaQueryData = hasAbnormalPadding
                ? mediaQueryData.copyWith(
                    viewPadding: fallbackPadding,
                    padding: fallbackPadding,
                    textScaler: const TextScaler.linear(1.0),
                  )
                : mediaQueryData.copyWith(textScaler: const TextScaler.linear(1.0));

            return MediaQuery(
              data: fixedMediaQueryData,
              child: Stack(
              children: [
                //侧键返回
                RawGestureDetector(
                  excludeFromSemantics: true,
                  gestures: <Type, GestureRecognizerFactory>{
                    FourthButtonTapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                            FourthButtonTapGestureRecognizer>(
                      () => FourthButtonTapGestureRecognizer(),
                      (FourthButtonTapGestureRecognizer instance) {
                        instance.onTapDown = (TapDownDetails details) async {
                          //如果处于全屏状态，退出全屏
                          if (!Platform.isAndroid && !Platform.isIOS) {
                            if (await windowManager.isFullScreen()) {
                              await windowManager.setFullScreen(false);
                              return;
                            }
                          }
                          Get.back();
                        };
                      },
                    ),
                  },
                  child: KeyboardListener(
                    focusNode: FocusNode(),
                    onKeyEvent: (KeyEvent event) async {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.escape) {
                        // ESC退出全屏
                        // 如果处于全屏状态，退出全屏
                        if (!Platform.isAndroid && !Platform.isIOS) {
                          if (await windowManager.isFullScreen()) {
                            await windowManager.setFullScreen(false);
                            return;
                          }
                        }
                      }
                    },
                    child: child!,
                  ),
                ),

                //查看DEBUG日志按钮
                //只在Debug、Profile模式显示
                Visibility(
                  visible: !kReleaseMode,
                  child: Positioned(
                    right: 12,
                    bottom: 100 + context.mediaQueryViewPadding.bottom,
                    child: Opacity(
                      opacity: 0.4,
                      child: ElevatedButton(
                        child: const Text("DEBUG LOG"),
                        onPressed: () {
                          Get.bottomSheet(
                            const DebugLogPage(),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
            );
          },
        ),
      );
    }));
  }
}
