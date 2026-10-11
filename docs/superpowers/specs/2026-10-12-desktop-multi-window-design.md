# 桌面端多开直播窗口 设计文档

日期：2026-10-12
状态：已确认，待实现

## 1. 目标

让 Simple Live 桌面端（Windows / macOS）支持多开独立直播窗口：在直播间列表项上长按
（或右键）选择「在新窗口打开」，为该直播间创建一个原生系统窗口。该窗口可独立拖动、
最小化、全屏、放到不同显示器，体验对齐斗鱼 / 虎牙官方桌面客户端。

非目标：不做托盘常驻、不做多窗口管理面板、不改 iOS / Android / Web 任何行为。

## 2. 调研结论

以下结论修正了初始设想中的三处假设，是本设计的依据。

### 2.1 desktop_multi_window 0.3.x 是重写版 API

pubspec 锁定 `desktop_multi_window: ^0.3.1`。0.3.0 是 breaking rewrite，
`MultiWindow.createWindow(args)` 已不存在。实际 API：

- `WindowController.create(WindowConfiguration(arguments:, hiddenAtLaunch:))` — 创建窗口
- `WindowController.fromCurrentEngine()` — 取当前窗口控制器（含 `windowId` 与 `arguments`）
- `WindowController.getAll()` — 列出全部窗口
- `WindowController.show()` / `.hide()` / `.invokeMethod()` / `.setWindowMethodHandler()`
- `WindowMethodChannel(name, mode:)` — 跨窗口通信
- `onWindowsChanged` — 窗口增删监听
- `WindowConfiguration` **只有** `arguments` 与 `hiddenAtLaunch` 两个字段，没有尺寸选项

插件支持 macOS（Swift / SwiftPM + podspec）、Windows（C++）、Linux（GTK）。
Dart 侧依赖仅有 flutter，macOS 最低 10.11，因此**不需要 window_manager fork**。

### 2.2 播放器本就是每实例独立

`lib/modules/live_room/player/player_controller.dart:30` 中 `late final player = Player(...)`
属于 `PlayerMixin`，由 GetX 在每次进入 `RoutePath.kLiveRoomDetail` 时新建的
`LiveRoomController`（继承 `PlayerController`）持有，不是全局单例。

每个子窗口是独立 Flutter engine + 独立 isolate + 独立 GetX 容器，
因此**天然获得独立的 `Player` 实例**，无需为多开改造播放器。

断流重试（`live_room_controller.dart` 的 `mediaErrorRetryCount`、
`_bufferingWatchdog`、`getPlayUrl()`）与缓冲看门狗同样是 controller 的实例字段，
每个窗口各自生效。commit `528df20`（缓冲看门狗）与 `2d7d5fd`（断流重试重新获取播放地址）
的逻辑天然按窗口隔离，无需改动。

### 2.3 真正的前置风险是子窗口原生插件注册

desktop_multi_window 为每个子窗口创建独立 Flutter engine，而 method channel
**不能跨 engine 共享**。不注册的话，子窗口里 `media_kit`、`window_manager`、
`path_provider` 等全部失效，表现为黑屏或 MissingPluginException。

必须在两个原生入口加注册回调，详见 §5.3。

### 2.4 其他关键约束

- **SyncService 端口冲突**：`services/sync_service.dart:41` 的 `onInit` 无条件
  `UDP.bind(23235)` 与 `shelf_io.serve(..., 23234)`。子窗口若复用 `initServices()`
  会直接抛 `SocketException: address already in use`。
- **window_manager 0.5.1 按 engine 解析窗口**：
  Windows 侧 `GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT)`，
  macOS 侧 `registrar.view?.window`。只要按 §5.3 注册，子窗口调用即作用于子窗口本身。
- **主窗口关闭即退出**：Windows `windows/runner/main.cpp` 有 `window.SetQuitOnClose(true)`；
  macOS `AppDelegate.swift` 有 `applicationShouldTerminateAfterLastWindowClosed -> true`。
  子窗口侧 `quit_on_close_` 默认为 `false`，关闭子窗口不会退出应用。
  **本次保持现状**：关闭主窗口 = 退出全部窗口，不改原生退出逻辑。
- **Hive 多 isolate 写入**：`LiveRoomController.addHistory()`
  （`live_room_controller.dart:350` / `:586`）在每次进入房间时写入共享 box。
  多窗口同时写入存在丢更新风险，见 §7 已知限制。

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
           ├─ Get.put(WindowArgsService(windowArgs))
           └─ runApp(ChildLiveRoomApp)  initialRoute = kChildLiveRoom
```

### 3.1 arguments 格式

单行 query string，URI 编码：

```
siteId=douyu&roomId=9999&title=xxx%20yyy
```

`WindowArgs` 负责 encode / decode。`siteId` 为空即视为主窗口。`title` 可选，
仅用于设置子窗口标题。

### 3.2 子窗口路由

新增 `RoutePath.kChildLiveRoom`，其 binding 从 `Get.find<WindowArgsService>()` 读取参数，
而非复用现有 `kLiveRoomDetail` binding 里对 `Get.arguments` / `Get.parameters` 的依赖
（`initialRoute` 场景下 GetX 的 arguments 传递不可靠）。

页面本身复用现有 `LiveRoomPage`，因此子窗口是**完整播放页**：弹幕、聊天、关注、
分享、设置抽屉全部可用。

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

## 4. 查重与聚焦

用户对同一直播间重复触发「新窗口打开」时，**聚焦已有窗口，不重复创建**。

```
AppNavigator.toLiveRoomInNewWindow(site:, roomId:)
  1. WindowController.getAll()
  2. 排除主窗口自身（其 arguments 中 siteId 为空），逐个解析比��� siteId + roomId
  3. 命中 → controller.invokeMethod('window_center')，返回
  4. 未命中 → WindowController.create(WindowConfiguration(
              arguments: WindowArgs(...).encode(),
              hiddenAtLaunch: true,
            ))
```

`window_center` 等自定义方法由子窗口侧通过 `setWindowMethodHandler` 提供，
内部委托给 `windowManager`（§2.4 已确认按 engine 生效）。

主窗口本身也可能正在播某个直播间，但它不在 `getAll()` 的候选里参与匹配 ——
从列表长按的场景下主窗口本来就在列表页；即便主窗口此刻正播同一房间，
用户长按列表项的语义是「我要另开一个窗口看它」，也应新建。

## 5. 文件改动清单

### 5.1 新增文件

| 文件 | 职责 |
|---|---|
| `lib/app/multi_window/window_args.dart` | `WindowArgs` 模型 + encode/decode；`isMainWindow` 判定 |
| `lib/app/multi_window/window_service.dart` | `MultiWindowService`：创建 / 查重 / 聚焦；`WindowController` 扩展（`center` / `close` / `setTitle`） |
| `lib/app/multi_window/child_live_room_app.dart` | `ChildLiveRoomApp` widget + `initChildServices()` 精简服务栈 |

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
| `lib/routes/route_path.dart` | 新增 `kChildLiveRoom` |
| `lib/routes/app_pages.dart` | 注册 `kChildLiveRoom`，binding 从 `WindowArgsService` 取参 |
| `lib/routes/app_navigation.dart` | 新增 `toLiveRoomInNewWindow(site:, roomId:)` |
| `lib/widgets/shadow_card.dart` | `InkWell` 增加可选 `onLongPress`（向后兼容，默认 null） |
| `lib/widgets/live_room_card.dart` | 桌面端长按 / 右键菜单（覆盖首页、分类详情、搜索结果） |
| `lib/modules/follow_user/follow_user_page.dart` | 同上（关注列表） |
| `lib/modules/mine/history/history_page.dart` | 同上（观看历史） |
| `lib/modules/live_room/player/player_controller.dart` | 音量按窗口隔离 |
| `lib/modules/live_room/player/player_controls.dart` | 音量滑块读写改走窗口内 `currentVolume` |

### 5.3 修改文件（原生）

| 文件 | 改动 |
|---|---|
| `windows/runner/flutter_window.cpp` | `OnCreate()` 中 `RegisterPlugins(registry)` 之后追加 `DesktopMultiWindowSetWindowCreatedCallback([](void* c){ RegisterPlugins(reinterpret_cast<flutter::FlutterViewController*>(c)->engine()); })`，并 include `desktop_multi_window/desktop_multi_window_plugin.h` |
| `macos/Runner/MainFlutterWindow.swift` | `RegisterGeneratedPlugins(registry:)` 之后追加 `FlutterMultiWindowPlugin.setOnWindowCreatedCallback { RegisterGeneratedPlugins(registry: $0) }`，并 `import desktop_multi_window` |

### 5.4 依赖

`pubspec.yaml` 已有 `desktop_multi_window: ^0.3.1`（当前工作区未提交）。
**不引入** window_manager fork，不引入任何仅移动端可用的依赖。

## 6. 平台隔离

多开功能仅在 Windows / macOS 可用，移动端行为零变化：

- 在 `window_args.dart` 定义 `bool get isMultiWindowPlatform => Platform.isWindows || Platform.isMacOS;`
  作为唯一判定点，避免散落的 `Platform.isX` 判断
- 所有新入口函数首行守卫 `if (!isMultiWindowPlatform) return;`
- 长按菜单入口挂在 `LiveRoomCard` / 关注列表 / 历史列表，
  仅当 `isMultiWindowPlatform` 为真时才挂 `onLongPress`
- 桌面端同时支持长按与右键（`Listener` 监听 `PointerDownEvent` + `kIsPrimary` 判断），
  移动端只保留原有单击行为
- `kChildLiveRoom` 路由只有子窗口会跳
- `desktop_multi_window` 仅声明 macOS / Windows / Linux 平台，不影响 Android / iOS / Web
- 音量隔离逻辑以标志位控制，主窗口（含全部移动端）走原有读写全局设置的路径

## 7. 已知限制

1. **Hive 多 isolate 写入竞争**：子窗口的 `addHistory()` 与主窗口写同一 box，
   并发写可能丢更新。按已确认的方案保留写入行为（只跳过 SyncService）。
   后续如需彻底解决，应改为由主窗口代理写入或加跨窗口互斥。
2. **多开成本**：每个子窗口是独立 engine + 独立 mpv 实例 + 独立弹幕 WebSocket 连接。
   开 N 个窗口约 N 倍解码 CPU 与弹幕带宽；且每个窗口都会重新拉一次流地址
   （斗鱼流地址约 300 秒过期，由各窗口自己的 `getPlayUrl()` 重试逻辑处理）。
3. **音量隔离不落盘**：子窗口音量只存内存，关闭窗口即丢失；主窗口音量行为不变。
4. **macOS 构建需先 `pod install`**：`desktop_multi_window` 的 pod 尚未进入
   当前 `Podfile.lock`（`flutter config --list` 显示 `enable-swift-package-manager: false`，
   插件同时提供 podspec）。未执行 `pod install` 时 `flutter build macos` 会报
   `No such module 'desktop_multi_window'`。
5. **Linux 未验证**：插件支持 Linux，但本次仅在 Windows / macOS 打开功能开关，
   Linux 保持现状。
6. **子窗口返回行为**：子窗口路由栈只有一层，`Get.back()` 无效，
   需特判为关闭窗口。

## 8. 验证方式

**编译验证**

```
cd simple_live_app/macos && pod install && cd ..
flutter build macos
flutter build windows
flutter analyze
```

`flutter analyze` 需确认移动端相关文件无新增告警。

**手工验证（需实机）**

1. 首页 / 分类 / 搜索 / 关注 / 历史列表长按 → 出现「在新窗口打开」
2. 菜单项在 iOS / Android 上不出现
3. 新窗口独立播放，音量独立（子窗口 A 调音量不影响 B）
4. 同一直播间重复触发 → 聚焦已有窗口，不新建
5. 子窗口可独立拖动、最小化、全屏
6. 子窗口内断流 → 自动重试并重新获取播放地址（斗鱼 300 秒过期场景）
7. 多开 3 个窗口时的 CPU / 内存占用

## 9. 明确不做

- 托盘常驻 / 关闭主窗口后继续运行
- 多窗口管理面板（列出已开窗口并聚焦 / 关闭）
- 在播放页「更多」菜单里加「新窗口打开」
- Linux 多开
- 移动端任何改动