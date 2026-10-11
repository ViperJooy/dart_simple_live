# 桌面端多开直播窗口 设计文档

日期：2026-10-12
状态：已确认（v2 — 交互模型已修订）

## 1. 目标

让 Simple Live 桌面端（Windows / macOS）支持多开独立直播窗口。

**交互模型（v2）**：桌面端点击任意直播间，默认直接在新窗口中打开。主窗口退化为
「浏览器」角色——只负责首页、分类、搜索、关注、历史、设置，永远不进入播放页。
每个直播间是一个可独立拖动、最小化、全屏、放到不同显示器的原生窗口。

这与斗鱼 / 虎牙官方桌面客户端一致，也避免了给已有的长按手势（历史删除、关注标签）
引入冲突。

非目标：不做托盘常驻、不做多窗口管理面板、不改 iOS / Android / Web 任何行为。

## 2. 调研结论

### 2.1 desktop_multi_window 0.3.x 是重写版 API

pubspec 锁定 `desktop_multi_window: ^0.3.1`。0.3.0 是 breaking rewrite，
`MultiWindow.createWindow(args)` 已不存在。实际 API：

- `WindowController.create(WindowConfiguration(arguments:, hiddenAtLaunch:))` — 创建窗口
- `WindowController.fromCurrentEngine()` — 取当前窗口控制器（含 `windowId` 与 `arguments`）
- `WindowController.getAll()` — 列出全部窗口
- `WindowController.show()` / `.hide()` / `.invokeMethod()` / `.setWindowMethodHandler()`
- `WindowMethodChannel(name, mode:)` — 跨窗口通信
- `onWindowsChanged` — 窗口增删监听
- `WindowConfiguration` **只有** `arguments` 与 `hiddenAtLaunch`，没有尺寸字段

插件支持 macOS（Swift / SwiftPM + podspec）、Windows（C++）、Linux（GTK）。
Dart 侧依赖仅有 flutter，macOS 最低 10.11，因此**不需要 window_manager fork**。

### 2.2 播放器本就是每实例独立

`lib/modules/live_room/player/player_controller.dart:30` 中 `late final player = Player(...)`
属于 `PlayerMixin`，由 GetX 在每次进入播放页时新建的 `LiveRoomController`
（继承 `PlayerController`）持有，不是全局单例。

每个子窗口是独立 Flutter engine + 独立 isolate + 独立 GetX 容器，
因此**天然获得独立的 `Player` 实例**，无需为多开改造播放器。

断流重试（`mediaErrorRetryCount`、`_bufferingWatchdog`、`getPlayUrl()`）与缓冲看门狗
同样是 controller 的实例字段，每个窗口各自生效。commit `528df20`（缓冲看门狗）与
`2d7d5fd`（断流重试重新获取播放地址）的逻辑天然按窗口隔离，无需改动。

### 2.3 真正的前置风险是子窗口原生插件注册

desktop_multi_window 为每个子窗口创建独立 Flutter engine，而 method channel
**不能跨 engine 共享**。不注册的话，子窗口里 `media_kit`、`window_manager`、
`path_provider` 等全部失效，表现为黑屏或 MissingPluginException。

必须在两个原生入口加注册回调，详见 §5.4。

### 2.4 其他关键约束

- **SyncService 端口冲突**：`services/sync_service.dart:41` 的 `onInit` 无条件
  `UDP.bind(23235)` 与 `shelf_io.serve(..., 23234)`。子窗口若复用 `initServices()`
  会直接抛 `SocketException: address already in use`。
- **window_manager 0.5.1 按 engine 解析窗口**：
  Windows 侧 `GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT)`，
  macOS 侧 `registrar.view?.window`。只要按 §5.4 注册，子窗口调用即作用于子窗口本身。
- **主窗口关闭即退出**：Windows `windows/runner/main.cpp` 有 `window.SetQuitOnClose(true)`；
  macOS `AppDelegate.swift` 有 `applicationShouldTerminateAfterLastWindowClosed -> true`。
  子窗口侧 `quit_on_close_` 默认为 `false`，关闭子窗口不会退出应用。
  **本次保持现状**：关闭主窗口 = 退出全部窗口，不改原生退出逻辑。
- **Hive 多 isolate 写入**：`LiveRoomController.addHistory()`
  （`live_room_controller.dart:350` / `:586`）在每次进入房间时写入共享 box。
  多窗口同时写入存在丢更新风险，见 §7 已知限制。

### 2.5 自动关闭定时器会杀掉整个应用（多开下的严重问题）

`live_room_controller.dart:189` 与 `:202` 的 `exit(0)` 解析到 **`dart:io` 的 `exit`**，
不是项目自定义方法——该文件导入了 `dart:io`，而 `BaseController` / `PlayerController`
都没有 `exit` 成员。

单窗口下这等价于「关掉应用」= 「关掉窗口」，无人察觉。多开下则是灾难：
**任意一个子窗口的自动关闭定时器到期，会终止整个进程，连带杀掉主窗口和所有其他
直播窗口。**

必须改为：子窗口关自己的窗口，主窗口与移动端保持原有 `exit(0)` 行为。详见 §5.3。

## 3. 整体架构

```
main()
 └─ WindowController.fromCurrentEngine() → 解析 arguments → WindowArgs
      ├─ WindowArgs.siteId == null   → 主窗口
      │    ├─ migrateData / initWindow（现有逻辑不动）
      │    ├─ MediaKit.ensureInitialized / Hive.initFlutter
      │    ├─ initServices()（含 SyncService）
      │    └─ runApp(MyApp)  initialRoute = kIndex
      │
      └─ WindowArgs.siteId != null   → 子窗口
           ├─ MediaKit.ensureInitialized / Hive.initFlutter
           ├─ initChildServices()（跳过 SyncService）
           ├─ Get.put(MultiWindowService(windowArgs))
           ├─ Get.put<LiveRoomController>(LiveRoomController(pSite:, pRoomId:))
           └─ runApp(ChildLiveRoomApp)
```

### 3.1 arguments 格式

单行 query string，URI 编码：

```
siteId=douyu&roomId=9999&title=xxx%20yyy
```

`WindowArgs` 负责 encode / decode。`siteId` 为空即视为主窗口。`title` 可选，
仅用于设置子窗口标题。

### 3.2 子窗口的路由结构

子窗口**不新增路由**。`ChildLiveRoomApp` 用 `home: LiveRoomPage()` 把播放页直接作为
根页面，同时 `getPages: AppPages.routes` 照常注册，使弹幕设置、播放设置、
关注标签等子页面仍能通过 `Get.toNamed` 正常 push。

`LiveRoomPage extends GetView<LiveRoomController>`，靠 `Get.find` 取控制器，
因此 `runApp` 之前必须先 `Get.put<LiveRoomController>(...)`。

现有的 `RoutePath.kLiveRoomDetail` 路由与其 binding 原样保留，仅移动端使用。

### 3.3 子窗口启动后的窗口设置

因 `WindowConfiguration` 无尺寸字段，子窗口在首帧后自行设置：

```
windowManager.setSize(...)     // 见下方尺寸规则
windowManager.center()
windowManager.setTitle("${title} - Simple Live")
windowManager.show()           // 配合 hiddenAtLaunch: true
```

**尺寸规则（确定性，不依赖播放状态）**：

- `siteId == "douyin"` → `480 x 854`
- 其他平台 → `854 x 480`

不用 `LiveRoomController.isVertical` 决定尺寸：该值在构造函数里只对抖音同步置真，
其余情况要等 `player.stream.width` / `height` 事件才有值，而窗口尺寸必须在首帧就定下来。
抖音竖屏是唯一可静态确定的情况，按 `siteId` 判定即可。

## 4. 打开与查重

改造 `AppNavigator.toLiveRoomDetail(site:, roomId:)`，桌面端改为开新窗口：

```
toLiveRoomDetail(site:, roomId:)
  ├─ B 站登录提示（现有逻辑，保持不变）
  ├─ isMultiWindowPlatform 为真  → MultiWindowService.instance.openRoom(site, roomId)
  │     1. WindowController.getAll()
  │     2. 逐个解析 arguments 比对 siteId + roomId
  │     3. 命中 → controller.invokeMethod('window_center')，聚焦，不新建
  │     4. 未命中 → WindowController.create(WindowConfiguration(
  │              arguments: WindowArgs(...).encode(),
  │              hiddenAtLaunch: true,
  │            ))
  └─ 否则 → Get.toNamed(RoutePath.kLiveRoomDetail, ...)（现有行为）
```

所有现有调用方（搜索结果、分类、首页、关注、历史、工具箱解析、抖音搜索）
都经过 `AppNavigator.toLiveRoomDetail`，因此**改这一处，桌面端全站点生效**。

主窗口本身不参与查重匹配——它的 arguments 里 `siteId` 为空。

`window_center` 由子窗口侧通过 `setWindowMethodHandler` 提供，内部委托
`windowManager`（§2.4 已确认按 engine 生效）。

## 5. 文件改动清单

### 5.1 新增文件

| 文件 | 职责 |
|---|---|
| `lib/app/multi_window/window_args.dart` | `WindowArgs` 模型 + encode/decode；`isMultiWindowPlatform` 唯一判定点 |
| `lib/app/multi_window/multi_window_service.dart` | `MultiWindowService`（GetxService，每窗口一个实例）：`openRoom` / `focus` / `closeSelf` / `setupSelfWindow`；`WindowController` 扩展 |
| `lib/app/multi_window/child_live_room_app.dart` | `ChildLiveRoomApp` + `initChildServices()` + 子窗口关闭时的资源回收 |

`initChildServices()` 精确内容（与 `main.dart` 现有 `initServices()` 对照）：

**执行**：`MediaKit.ensureInitialized()`、`Hive.initFlutter(...)`、
`Hive.registerAdapter` ×3、`Utils.packageInfo`、`LocalStorageService.init()`、
`DBService.init()`、`AppSettingsController`、`BiliBiliAccountService`、
`DouyinAccountService`、`FollowService`、`initCoreLog()`

**跳过**：`SyncService`（§2.4 端口冲突）

上述服务足以支撑完整的 `LiveRoomPage`：关注状态走 `FollowService` / `DBService`，
历史写入走 `DBService`，B 站高画质走 `BiliBiliAccountService`，主题与播放器参数走
`AppSettingsController`。`SyncService` 只服务于局域网同步，子窗口用不到。

### 5.2 修改文件（Dart）

| 文件 | 改动 |
|---|---|
| `lib/main.dart` | 读取 `WindowController.fromCurrentEngine()`，分流主 / 子窗口入口 |
| `lib/routes/app_navigation.dart` | `toLiveRoomDetail` 桌面端分支改为开新窗口 |
| `lib/modules/live_room/player/player_controller.dart` | 音量按窗口隔离；新增 `closeSelf()` |
| `lib/modules/live_room/live_room_controller.dart` | `exit(0)` ×2 改为 `closeSelf()`；音量滑块改走窗口内音量 |

### 5.3 子窗口关闭时的资源回收

commit `067833b` 记录了一个 Windows 崩溃：`dispose` 注销纹理时若与仍在渲染的
mpv 线程竞争，会触发 `0xc0000005`。现有 `PlayerController.onClose` 的做法是
先 `await player.stop()` 再 `await player.dispose()`。

窗口被关闭时 engine 直接销毁，GetX 的 `onClose` **不保证执行**，因此必须显式回收：

- 子窗口启动时 `windowManager.setPreventClose(true)` 并注册 `WindowListener`
- `onWindowClose()` → `await controller.teardown()` → `setPreventClose(false)` → `close()`
- `teardown()` 从现有 `onClose()` 抽出，并用幂等标志位保护，
  避免与 GetX 后续的 `onClose` 重复释放

### 5.4 修改文件（原生）

| 文件 | 改动 |
|---|---|
| `windows/runner/flutter_window.cpp` | `OnCreate()` 中 `RegisterPlugins(registry)` 之后追加 `DesktopMultiWindowSetWindowCreatedCallback([](void* c){ RegisterPlugins(reinterpret_cast<flutter::FlutterViewController*>(c)->engine()); })`，并 include `desktop_multi_window/desktop_multi_window_plugin.h` |
| `macos/Runner/MainFlutterWindow.swift` | `RegisterGeneratedPlugins(registry:)` 之后追加 `FlutterMultiWindowPlugin.setOnWindowCreatedCallback { RegisterGeneratedPlugins(registry: $0) }`，并 `import desktop_multi_window` |

### 5.5 依赖与测试

`pubspec.yaml` 已有 `desktop_multi_window: ^0.3.1`（当前工作区未提交）。
**不引入** window_manager fork，不引入任何仅移动端可用的依赖。

`test/widget_test.dart` 目前是 Flutter 计数器模板残留，`flutter test` 在改动前
**就已经失败**。用真实的 `WindowArgs` 单元测试替换它，使 `flutter test` 恢复可用。

## 6. 平台隔离

多开功能仅在 Windows / macOS 可用，移动端行为零变化：

- `window_args.dart` 定义 `bool get isMultiWindowPlatform => Platform.isWindows || Platform.isMacOS;`
  作为唯一判定点，避免散落的 `Platform.isX` 判断
- `AppNavigator.toLiveRoomDetail` 在 `isMultiWindowPlatform` 为假时，
  走的仍是原来那行 `Get.toNamed`
- `desktop_multi_window` 仅声明 macOS / Windows / Linux 平台，不影响 Android / iOS / Web
- 音量隔离与 `closeSelf()` 均以「是否子窗口」为条件分支，移动端行为不变

## 7. 已知限制

1. **`exit(0)` 全局杀进程**：§2.5 的问题本设计已修复，但需注意该调用点历史上
   一直存在；本次改动后子窗口不再触发全局退出。
2. **Hive 多 isolate 写入竞争**：子窗口的 `addHistory()` 与主窗口写同一 box，
   并发写可能丢更新。按已确认的方案保留写入行为（只跳过 SyncService）。
   后续如需彻底解决，应改为由主窗口代理写入或加跨窗口互斥。
3. **多开成本**：每个子窗口是独立 engine + 独立 mpv 实例 + 独立弹幕 WebSocket 连接。
   开 N 个窗口约 N 倍解码 CPU 与弹幕带宽；且每个窗口都会重新拉一次流地址
   （斗鱼流地址约 300 秒过期，由各窗口自己的 `getPlayUrl()` 重试逻辑处理）。
4. **音量隔离不落盘**：子窗口音量只存内存，关闭窗口即丢失；主窗口音量行为不变。
5. **macOS 构建需先 `pod install`**：`desktop_multi_window` 的 pod 尚未进入
   当前 `Podfile.lock`（`flutter config --list` 显示 `enable-swift-package-manager: false`，
   插件同时提供 podspec）。未执行 `pod install` 时 `flutter build macos` 会报
   `No such module 'desktop_multi_window'`。
6. **Linux 未验证**：插件支持 Linux，但本次仅在 Windows / macOS 打开功能开关。
7. **工作区存在无关的本地工具链漂移**（与本功能无关，不应混入提交）：
   `Podfile` 平台版本 10.14→10.15、`Podfile.lock`（CocoaPods 1.11.3→1.16.2）、
   `pbxproj` 的 `LastUpgradeCheck 1300→1510`、`AppDelegate.swift` 的
   `@NSApplicationMain`→`@main`、iOS `AppFrameworkInfo.plist` 删除
   `MinimumOSVersion`。这些来自本地 Xcode / CocoaPods 升级，
   `desktop_multi_window` 的 podspec 只要求 macOS 10.11。

## 8. 验证方式

**单元测试**

```
cd simple_live_app && flutter test
```

覆盖 `WindowArgs` 编解码、平台判定边界。

**编译验证**

```
cd simple_live_app/macos && pod install && cd ..
flutter build macos
flutter build windows
flutter analyze
```

`flutter analyze` 需确认移动端相关文件无新增告警。

**手工验证（需实机）**

1. 桌面端点击任意直播间 → 新窗口打开并播放，主窗口停留在列表页
2. iOS / Android 上点击直播间 → 仍在主窗口内进入播放页（行为不变）
3. 同一直播间重复点击 → 聚焦已有窗口，不新建
4. 子窗口可独立拖动、最小化、全屏、跨显示器
5. 子窗口音量独立（调 A 不影响 B，且不写回全局设置）
6. 关闭子窗口 → 无崩溃（验证 teardown 幂等与 stop-then-dispose 顺序）
7. 子窗口内断流 → 自动重试并重新获取播放地址（斗鱼 300 秒过期场景）
8. 主窗口定时关闭不生效（主窗口不进播放页，无定时器）
9. 子窗口定时关闭到期 → 只关该子窗口，其他窗口与应用存活
10. 多开 3 个窗口时的 CPU / 内存占用

## 9. 明确不做

- 托盘常驻 / 关闭主窗口后继续运行
- 多窗口管理面板（列出已开窗口并聚焦 / 关闭）
- 长按菜单形式的「在新窗口打开」入口
- 播放页「更多」菜单里的「新窗口打开」
- Linux 多开
- 移动端任何改动