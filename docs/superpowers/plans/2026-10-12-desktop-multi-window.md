# 桌面端多开直播窗口 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Simple Live 桌面端点击任意直播间时，在独立原生窗口中打开播放，主窗口退化为只负责浏览的「浏览器窗口」。

**Architecture:** 用 `desktop_multi_window` 0.3.x 的 `WindowController` API。`main()` 先读 `WindowController.fromCurrentEngine()` 拿到本窗口的 `arguments`，据此分流主窗口 / 子窗口。子窗口跑精简服务栈（跳过 `SyncService`），把 `LiveRoomPage` 直接作为根页面。`AppNavigator.toLiveRoomDetail` 在桌面端改为创建或聚焦窗口，移动端走原路径。

**Tech Stack:** Flutter / Dart 3、GetX（状态 + 路由）、media_kit + media_kit_video、window_manager 0.5.1、desktop_multi_window 0.3.1

**Spec:** `docs/superpowers/specs/2026-10-12-desktop-multi-window-design.md`

## Global Constraints

这些约束来自 spec，每个 task 的要求都隐含包含本节：

- **仅桌面端**：`lib/app/multi_window/window_args.dart` 中的 `isMultiWindowPlatform`（`Platform.isWindows || Platform.isMacOS`）是唯一判定点。移动端行为必须与改动前完全一致。
- **不引入** window_manager fork，不引入任何仅移动端可用的依赖。`pubspec.yaml` 已有 `desktop_multi_window: ^0.3.1`，无需再加。
- **播放器不得改为全局单例**。`PlayerController` 保持每实例独立，这是既有设计（spec §2.2）。
- **播放器释放顺序**：`await player.stop()` 必须在 `await player.dispose()` 之前（commit `067833b`，否则 Windows 上 `0xc0000005` 崩溃）。
- **代码风格**：GetX 状态管理、现有 `routes/` 写法、中文注释、`Utils.showBottomSheet` / `AppNavigator` 等既有工具函数。
- **commit message 不带 `Co-Authored-By` 行。**
- **不改 CI 配置。**
- **不提交与本功能无关的工作区改动**（见 spec §7.7：Podfile / Podfile.lock / pbxproj / AppDelegate / iOS plist）。每次 commit 只 `git add` 本 task 明确列出的文件。
- API 以 `desktop_multi_window` 0.3.1 为准：`WindowController.create(WindowConfiguration)`、`fromCurrentEngine()`、`getAll()`、`invokeMethod()`、`setWindowMethodHandler()`。**不存在** `MultiWindow.createWindow()`。

## Review Focus

spec 是愿景文档，它的沉默不等于许可。这五类输入 / 失败模式最可能咬人，按可能性排序：

1. **子窗口是移动端平台判定漏网** —— 用户在 Android 上点击直播间。如果 `toLiveRoomDetail` 的桌面分支判定写错，移动端会开出一个无法初始化的窗口。→ 由 Task 5 的测试锁定。
2. **子窗口自动关闭定时器杀掉整个应用** —— `live_room_controller.dart:189/202` 的 `exit(0)` 解析到 `dart:io` 的 `exit`。多开下任一子窗口定时器到期会终止全进程。→ 由 Task 6 的测试锁定。
3. **关闭子窗口时 mpv 线程与纹理注销竞争崩溃** —— 窗口销毁时 engine 直接死掉，GetX `onClose` 不保证执行，播放器没被 stop/dispose 就没了。Windows 上表现为 `0xc0000005` 闪退。→ 由 Task 7 的测试锁定。
4. **音量从子窗口泄漏回全局设置** —— 用户在子窗口 A 调音量，主窗口和子窗口 B 的音量跟着变，或设置被持久化后下次启动生效。→ 由 Task 6 的测试锁定。
5. **子窗口复用 `initServices()` 导致端口绑定抛异常** —— `SyncService.onInit` 无条件 `UDP.bind(23235)` + shelf HTTP `23234`，第二个窗口必抛 `SocketException: address already in use`，子窗口白屏。→ 由 Task 4 的测试锁定。

---

## File Structure

**新增**

| 文件 | 单一职责 |
|---|---|
| `lib/app/multi_window/window_args.dart` | 窗口启动参数的编解码，以及 `isMultiWindowPlatform` 判定 |
| `lib/app/multi_window/multi_window_service.dart` | 打开/聚焦/关闭子窗口，子窗口自身设置，跨窗口方法处理器 |
| `lib/app/multi_window/child_live_room_app.dart` | 子窗口的精简服务栈初始化 + 子窗口 GetMaterialApp + 关闭时资源回收 |

**修改**

| 文件 | 改动 |
|---|---|
| `lib/main.dart` | 主/子窗口分流入口 |
| `lib/routes/app_navigation.dart` | 桌面端点击直播间开新窗口 |
| `lib/modules/live_room/player/player_controller.dart` | 音量按窗口隔离、`closeSelf()`、`teardown()` |
| `lib/modules/live_room/live_room_controller.dart` | `exit(0)` → `closeSelf()`，音量滑块 |
| `windows/runner/flutter_window.cpp` | 子窗口 engine 注册插件 |
| `macos/Runner/MainFlutterWindow.swift` | 子窗口 engine 注册插件 |
| `test/widget_test.dart` | 替换失效的计数器模板测试 |

---

### Task 1: WindowArgs 编解码与平台判定

**Files:**
- Create: `simple_live_app/lib/app/multi_window/window_args.dart`
- Create: `simple_live_app/test/window_args_test.dart`
- Delete: `simple_live_app/test/widget_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class WindowArgs { final String siteId; final String roomId; final String title; const WindowArgs({required this.siteId, required this.roomId, this.title = ''}); bool get isMainWindow => siteId.isEmpty; String encode(); static WindowArgs decode(String raw); }`
  - `bool get isMultiWindowPlatform`（top-level，`Platform.isWindows || Platform.isMacOS`）

- [ ] **Step 1: 删除失效的计数器模板测试**

`test/widget_test.dart` 是 Flutter 模板残留，找一个不存在的计数器，`flutter test` 在本改动之前就已经失败。删除它，让后续测试有干净的起点。

```bash
rm simple_live_app/test/widget_test.dart
```

- [ ] **Step 2: 写失败测试**

创建 `simple_live_app/test/window_args_test.dart`：

```dart
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
      const args = WindowArgs(siteId: 'huya', roomId: '123', title: '测试 主播 & 房');
      expect(args.encode(), 'siteId=huya&roomId=123&title=%E6%B5%8B%E8%AF%95%20%E4%B8%BB%E6%92%AD%20%26%20%E6%88%BF');
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
      expect(const WindowArgs(siteId: 'douyu', roomId: '1').isMainWindow, isFalse);
    });
  });

  group('isMultiWindowPlatform', () {
    test('当前运行平台的值与 Platform 实际一致', () {
      expect(isMultiWindowPlatform, Platform.isWindows || Platform.isMacOS);
    });
  });
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: FAIL — `Error: Error when reading 'lib/app/multi_window/window_args.dart': no such file` 或 `The library ... can't be imported`（文件还不存在）。

- [ ] **Step 4: 实现 `window_args.dart`**

创建 `simple_live_app/lib/app/multi_window/window_args.dart`：

```dart
import 'dart:io';

/// 是否支持多窗口的平台
///
/// 这是全项目判断「是否走多窗口分支」的唯一入口，避免散落的 Platform 判断。
bool get isMultiWindowPlatform => Platform.isWindows || Platform.isMacOS;

/// 子窗口启动参数
///
/// 通过 desktop_multi_window 的 WindowConfiguration.arguments 传递给子窗口。
/// siteId 为空表示主窗口。
class WindowArgs {
  /// 平台 id，对应 simple_live_core 的 Site.id
  final String siteId;

  /// 直播间 id
  final String roomId;

  /// 主播名，仅用于设置窗口标题，可为空
  final String title;

  const WindowArgs({
    required this.siteId,
    required this.roomId,
    this.title = '',
  });

  /// 是否为主窗口（主窗口没有直播间参数）
  bool get isMainWindow => siteId.isEmpty;

  /// 编码为 desktop_multi_window 的 arguments 字符串
  String encode() {
    final map = <String, String>{
      'siteId': siteId,
      'roomId': roomId,
    };
    if (title.isNotEmpty) {
      map['title'] = title;
    }
    return map.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  /// 解析 arguments 字符串
  factory WindowArgs.decode(String raw) {
    if (raw.isEmpty) {
      return const WindowArgs(siteId: '', roomId: '');
    }
    final map = <String, String>{};
    for (final pair in raw.split('&')) {
      final index = pair.indexOf('=');
      if (index <= 0) continue;
      final key = Uri.decodeQueryComponent(pair.substring(0, index));
      final value = Uri.decodeQueryComponent(pair.substring(index + 1));
      map[key] = value;
    }
    return WindowArgs(
      siteId: map['siteId'] ?? '',
      roomId: map['roomId'] ?? '',
      title: map['title'] ?? '',
    );
  }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: PASS — 全部用例通过，末行形如 `00:0X +X: All tests passed!`

- [ ] **Step 6: 运行全量测试确认基线干净**

Run: `cd simple_live_app && flutter test`
Expected: PASS — 全部通过。（改动前此命令是失败的，因为有计数器模板测试。）

- [ ] **Step 7: 提交**

```bash
git add simple_live_app/test/window_args_test.dart simple_live_app/lib/app/multi_window/window_args.dart
git rm --cached simple_live_app/test/widget_test.dart
git commit -m "feat: 添加多窗口启动参数编解码与平台判定

删除失效的 Flutter 计数器模板测试，替换为 WindowArgs 单元测试，
使 flutter test 恢复可用。"
```

---

### Task 2: 原生子窗口插件注册

这是整个功能的**前置条件**：desktop_multi_window 为每个子窗口创建独立 Flutter engine，
而 method channel 不跨 engine 共享。不注册的话子窗口里 media_kit / window_manager /
path_provider 全部失效，表现为黑屏。

**Files:**
- Modify: `simple_live_app/windows/runner/flutter_window.cpp`
- Modify: `simple_live_app/macos/Runner/MainFlutterWindow.swift`

**Interfaces:**
- Consumes: 无
- Produces: 无 Dart 侧接口。这是给后续所有 task 提供媒体播放能力的运行时前提。

- [ ] **Step 1: 先确认当前 macOS 构建状态**

Run: `cd simple_live_app && grep -c desktop_multi_window macos/Podfile.lock || echo "pod 缺失"`

Expected: 输出 `0` 或 `pod 缺失`。`desktop_multi_window` 的 pod 尚未安装
（`flutter config --list` 显示 `enable-swift-package-manager: false`，但插件同时提供
podspec）。这是**改动前就存在的状态**，Step 3 会修好它。

- [ ] **Step 2: Windows 侧注册子窗口插件**

修改 `simple_live_app/windows/runner/flutter_window.cpp`。在文件顶部的 include 区
（`#include "flutter/generated_plugin_registrant.h"` 之后）加入：

```cpp
#include "desktop_multi_window/desktop_multi_window_plugin.h"
```

然后在 `FlutterWindow::OnCreate()` 中，把现有的

```cpp
  RegisterPlugins(flutter_controller_->engine());
```

改为

```cpp
  RegisterPlugins(flutter_controller_->engine());
  // desktop_multi_window 为每个子窗口创建独立 engine，method channel 不跨 engine
  // 共享，必须为子窗口单独注册插件，否则子窗口内 media_kit / window_manager 全部失效
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
  });
```

- [ ] **Step 3: macOS 侧注册子窗口插件并安装 pod**

修改 `simple_live_app/macos/Runner/MainFlutterWindow.swift`。在 import 区加入：

```swift
import desktop_multi_window
```

然后把 `awakeFromNib()` 中现有的

```swift
    RegisterGeneratedPlugins(registry: flutterViewController)
```

改为

```swift
    RegisterGeneratedPlugins(registry: flutterViewController)

    // desktop_multi_window 为每个子窗口创建独立 engine，method channel 不跨 engine
    // 共享，必须为子窗口单独注册插件，否则子窗口内 media_kit / window_manager 全部失效
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
    }
```

然后安装 pod（`GeneratedPluginRegistrant.swift` 已经 `import desktop_multi_window`，
但 `Podfile.lock` 里没有这个 pod，不装会报 `No such module`）：

Run: `cd simple_live_app/macos && pod install`
Expected: 输出包含 `Installing desktop_multi_window` 或 Podfile.lock 的 PODS 段新增该条目。

- [ ] **Step 4: 验证 pod 已进入 lock 文件**

Run: `cd simple_live_app && grep -A1 "desktop_multi_window" macos/Podfile.lock | head -3`
Expected: 输出包含 `desktop_multi_window`。若仍为空，`pod install` 未生效，重跑 Step 3。

- [ ] **Step 5: 提交**

```bash
git add simple_live_app/windows/runner/flutter_window.cpp simple_live_app/macos/Runner/MainFlutterWindow.swift
git commit -m "feat: 为多窗口子窗口注册原生插件

desktop_multi_window 为每个子窗口创建独立 Flutter engine，method channel
不跨 engine 共享。不注册的话子窗口内 media_kit、window_manager 全部失效。"
```

> 注意：`macos/Podfile.lock` 因 `pod install` 产生改动，属于本 task 的必要产物，
> 但它同时混有本地 CocoaPods 1.11.3→1.16.2 的无关漂移（spec §7.7）。
> 提交前用 `git diff macos/Podfile.lock` 确认，若无法拆分则留到最后一个 task 与
> 负责人确认。本步先只提交两个源文件。

---

### Task 3: MultiWindowService

**Files:**
- Create: `simple_live_app/lib/app/multi_window/multi_window_service.dart`

**Interfaces:**
- Consumes: Task 1 的 `WindowArgs`、`isMultiWindowPlatform`
- Produces:
  - `class MultiWindowService extends GetxService`，实例通过 `Get.find<MultiWindowService>()` 获取
  - `MultiWindowService({required this.windowId, required this.windowArgs})`
  - `bool get isChildWindow` — `!windowArgs.isMainWindow`
  - `Future<void> openRoom({required Site site, required String roomId, String title})` — 创建或聚焦子窗口
  - `Future<void> focusWindow(WindowController controller)` — `window_center`
  - `Future<void> closeSelf()` — 关闭本窗口（子窗口有效）
  - `Future<void> setupSelfWindow()` — 子窗口设置尺寸/居中/标题后 show
  - `extension WindowControllerExtension on WindowController`：`center()`、`closeSelfWindow()`

**依赖提示**：本 task 无法用 `flutter test` 覆盖（全部方法依赖 platform channel）。
测试策略：本 task 只做静态验证，运行时行为由 Task 8 的手工验证清单覆盖。

- [ ] **Step 1: 创建 service**

创建 `simple_live_app/lib/app/multi_window/multi_window_service.dart`：

```dart
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_core/simple_live_core.dart';
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

  /// 子窗口首帧后设置自己的窗口属性并显示
  ///
  /// WindowConfiguration 没有尺寸字段，只能由子窗口自行设置。
  Future<void> setupSelfWindow() async {
    if (!isChildWindow) return;
    try {
      final size = _childWindowSize[windowArgs.siteId] ?? _defaultChildWindowSize;
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
```

- [ ] **Step 2: 确认接口自洽**

`closeSelf()` 是 `MultiWindowService` 的成员方法，不是 `WindowController` 的，
所以扩展方法 `closeSelfWindow()` 无法在实例方法里直接以 `this.` 调用——
必须先 `WindowController.fromWindowId(windowId)` 取出控制器再调。
上面的实现已经这样写了，不要简化成 `await closeSelfWindow()`。

Run: `cd simple_live_app && flutter analyze lib/app/multi_window/`
Expected: 无 error。若报 `MissingPluginException` 未定义，补
`import 'package:flutter/services.dart';`。

- [ ] **Step 3: 提交**

```bash
git add simple_live_app/lib/app/multi_window/multi_window_service.dart
git commit -m "feat: 添加多窗口服务，创建与聚焦子窗口"
```

---

### Task 4: 子窗口精简服务栈与入口

**Files:**
- Create: `simple_live_app/lib/app/multi_window/child_live_room_app.dart`
- Modify: `simple_live_app/lib/main.dart`
- Modify: `simple_live_app/test/window_args_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `WindowArgs`、`isMultiWindowPlatform`；Task 3 的 `MultiWindowService`
- Produces:
  - `Future<void> initChildServices()` — 精简服务栈，不含 `SyncService`
  - `class ChildLiveRoomApp extends StatelessWidget`，构造参数 `const ChildLiveRoomApp({super.key})`

- [ ] **Step 1: 写失败测试：子窗口服务栈不得包含 SyncService**

在 `simple_live_app/test/window_args_test.dart` 末尾追加：

```dart
  group('子窗口服务栈', () {
    test('initChildServices 的实现不注册 SyncService', () {
      final source = File('lib/app/multi_window/child_live_room_app.dart').readAsStringSync();
      expect(source, contains('initChildServices'));
      // SyncService.onInit 会无条件绑定 UDP 23235 与 HTTP 23234，
      // 第二个窗口必然 SocketException，子窗口不得初始化它
      expect(source.contains('SyncService'), isFalse);
    });
  });
```

并在文件顶部补 `import 'dart:io';`（若已存在则跳过）。

这个测试是源码断言而非行为断言，但它锁住的是一条会导致子窗口白屏的硬约束，
比没有测试强。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: FAIL — `PathNotFoundException` 或 `contains('initChildServices')` 不满足（文件不存在）。

- [ ] **Step 3: 创建 `child_live_room_app.dart`**

创建 `simple_live_app/lib/app/multi_window/child_live_room_app.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multi_window/multi_window_service.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/widgets/app_loadding_widget.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/app/log.dart';

/// 子窗口的精简服务栈
///
/// 与 main.dart 的 initServices() 的唯一区别：**不注册 SyncService**。
/// SyncService.onInit 会无条件 UDP.bind(23235) 与 shelf serve 23234，
/// 第二个窗口必然抛 SocketException(address already in use)，子窗口白屏。
///
/// 其余服务都是播放页必需的：关注状态走 FollowService/DBService，
/// 历史写入走 DBService，B 站高画质走 BiliBiliAccountService，
/// 主题与播放器参数走 AppSettingsController。
Future<void> initChildServices() async {
  Hive.registerAdapter(FollowUserAdapter());
  Hive.registerAdapter(HistoryAdapter());
  Hive.registerAdapter(FollowUserTagAdapter());

  Utils.packageInfo = await PackageInfo.fromPlatform();
  Log.d("Init LocalStorage Service (child window)");
  await Get.put(LocalStorageService()).init();
  await Get.put(DBService()).init();
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
class ChildLiveRoomApp extends StatelessWidget {
  const ChildLiveRoomApp({super.key});

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
      home: const LiveRoomPage(),
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.0)),
          child: child!,
        ),
      ),
    );
  }
}
```

补齐缺失的 import：`package:hive_flutter/hive_flutter.dart`（`Hive`）、
`package:package_info_plus/package_info_plus.dart`（`PackageInfo`）。
`initCoreLog()` 与 `Log` 来自 `lib/main.dart` 与 `lib/app/log.dart`，均为公开顶层成员，
直接调用即可，不需要搬家。

- [ ] **Step 4: 在 `main.dart` 分流主/子窗口**

修改 `simple_live_app/lib/main.dart`。把 `void main() async {` 的开头改为：

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
      await runChildWindow(controller);
      return;
    }
  }

  await migrateData();
  await initWindow();
  // ... 以下保持原样
```

新增函数：

```dart
/// 子窗口入口
Future<void> runChildWindow(WindowController controller) async {
  final service = Get.find<MultiWindowService>();
  final windowArgs = service.windowArgs;

  MediaKit.ensureInitialized();
  await Hive.initFlutter((await getApplicationSupportDirectory()).path);
  await initChildServices();
  await service.registerChildWindowHandler();

  Get.put<LiveRoomController>(LiveRoomController(
    pSite: Sites.allSites[windowArgs.siteId]!,
    pRoomId: windowArgs.roomId,
  ));

  runApp(const ChildLiveRoomApp());

  // 首帧后再设置窗口属性与显示
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await service.setupSelfWindow();
  });
}
```

`runChildWindow` 从 `Get.find<MultiWindowService>()` 取 service 而不是重新构造，
因为 `main()` 里已经用当前窗口的 `controller.windowId` 注册过了。

同时在 `main.dart` 顶部补 import：
`package:desktop_multi_window/desktop_multi_window.dart`、
`package:simple_live_app/app/multi_window/window_args.dart`、
`package:simple_live_app/app/multi_window/multi_window_service.dart`、
`package:simple_live_app/app/multi_window/child_live_room_app.dart`。

- [ ] **Step 5: 运行测试确认通过**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: PASS。

- [ ] **Step 6: 静态检查**

Run: `cd simple_live_app && flutter analyze`
Expected: 无 error。warning 数量不超过改动前基线。

- [ ] **Step 7: 提交**

```bash
git add simple_live_app/lib/app/multi_window/child_live_room_app.dart simple_live_app/lib/main.dart simple_live_app/test/window_args_test.dart
git commit -m "feat: 添加子窗口入口与精简服务栈

子窗口不注册 SyncService——它的 onInit 会无条件绑定 UDP 23235 与
HTTP 23234，第二个窗口必然端口冲突。播放页作为子窗口根页面。"
```

---

### Task 5: 桌面端点击直播间开新窗口

**Files:**
- Modify: `simple_live_app/lib/routes/app_navigation.dart`
- Modify: `simple_live_app/test/window_args_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `isMultiWindowPlatform`；Task 3 的 `MultiWindowService.openRoom`
- Produces: `AppNavigator.toLiveRoomDetail({required Site site, required String roomId})` 行为变更 —— 桌面端开新窗口，移动端不变

- [ ] **Step 1: 写失败测试**

在 `simple_live_app/test/window_args_test.dart` 末尾追加：

```dart
  group('toLiveRoomDetail 平台隔离', () {
    test('非多窗口平台时走原有 Get.toNamed 路径', () {
      final source = File('lib/routes/app_navigation.dart').readAsStringSync();
      expect(source, contains('isMultiWindowPlatform'));
      // 桌面分支必须在平台判定之内，移动端分支保持原样
      expect(source, contains('RoutePath.kLiveRoomDetail'));
      expect(source, contains('MultiWindowService'));
    });
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: FAIL — `contains('isMultiWindowPlatform')` 不满足。

- [ ] **Step 3: 改造 `toLiveRoomDetail`**

修改 `simple_live_app/lib/routes/app_navigation.dart`。
把方法末尾的

```dart
    Get.toNamed(RoutePath.kLiveRoomDetail, arguments: site, parameters: {
      "roomId": roomId,
    });
```

改为

```dart
    // 桌面端：点击直播间直接开新窗口，主窗口只负责浏览
    if (isMultiWindowPlatform) {
      await Get.find<MultiWindowService>()
          .openRoom(site: site, roomId: roomId, title: '');
      return;
    }

    Get.toNamed(RoutePath.kLiveRoomDetail, arguments: site, parameters: {
      "roomId": roomId,
    });
```

在文件顶部补 import：
`package:simple_live_app/app/multi_window/window_args.dart`、
`package:simple_live_app/app/multi_window/multi_window_service.dart`。

`Get.find<MultiWindowService>()` 依赖 Task 4 Step 4 已在主窗口注册的实例。
若报找不到实例，回查 Task 4 Step 4 的 `main()` 开头是否漏了主窗口分支的
`Get.put(MultiWindowService(...))`。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: PASS。

- [ ] **Step 5: 静态检查**

Run: `cd simple_live_app && flutter analyze lib/routes/`
Expected: 无 error。

- [ ] **Step 6: 提交**

```bash
git add simple_live_app/lib/routes/app_navigation.dart simple_live_app/test/window_args_test.dart
git commit -m "feat: 桌面端点击直播间在新窗口打开

移动端保持原有 Get.toNamed 路径不变。"
```

---

### Task 6: 音量按窗口隔离 + closeSelf

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/player/player_controller.dart`
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`
- Modify: `simple_live_app/test/window_args_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `MultiWindowService.isChildWindow`
- Produces:
  - `PlayerController.currentVolume` — `RxDouble`
  - `PlayerController.isIndependentVolume` — `bool`
  - `PlayerController.setVolume(double)` — 写入玩家并按需持久化
  - `PlayerController.closeSelf()` — 子窗口关自己，主窗口/移动端 `exit(0)`

- [ ] **Step 1: 写失败测试**

在 `simple_live_app/test/window_args_test.dart` 末尾追加：

```dart
  group('子窗口不终止整个进程', () {
    test('live_room_controller 不再直接调用 dart:io 的 exit', () {
      final source = File('lib/modules/live_room/live_room_controller.dart').readAsStringSync();
      // exit(0) 解析到 dart:io 的 exit，多开下任一子窗口定时器到期会杀掉全进程
      expect(source.contains('exit(0)'), isFalse);
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: FAIL — `contains('exit(0)')` 仍为 true。

- [ ] **Step 3: 在 `PlayerController` 加入窗口内音量与 `closeSelf`**

修改 `simple_live_app/lib/modules/live_room/player/player_controller.dart`。

在 `PlayerMixin` 中，`player` 字段之后加入：

```dart
  /// 是否按窗口隔离音量
  ///
  /// 子窗口为 true：音量只存内存，不写全局 LocalStorage，关闭即丢失。
  /// 主窗口与全部移动端为 false：沿用既有读写全局设置的路径。
  bool get isIndependentVolume {
    if (!isMultiWindowPlatform) return false;
    return _isChildWindow;
  }

  bool get _isChildWindow {
    if (!Get.isRegistered<MultiWindowService>()) return false;
    return Get.find<MultiWindowService>().isChildWindow;
  }

  /// 当前窗口的播放器音量
  late final RxDouble currentVolume = RxDouble(
    AppSettingsController.instance.playerVolume.value,
  );
```

在 `PlayerController.onInit()` 中，把

```dart
    //设置音量
    player.setVolume(AppSettingsController.instance.playerVolume.value);
```

改为

```dart
    // 设置音量：子窗口独立内存值，主窗口沿用全局设置
    player.setVolume(currentVolume.value);
```

在 `PlayerController` 类体中追加：

```dart
  /// 设置播放器音量
  ///
  /// 子窗口只改内存值，避免多开时各窗口互相覆盖全局设置。
  void setVolume(double value) {
    currentVolume.value = value;
    player.setVolume(value);
    if (!isIndependentVolume) {
      AppSettingsController.instance.setPlayerVolume(value);
    }
  }

  /// 关闭当前播放窗口
  ///
  /// 子窗口只关自己；主窗口与移动端保持原有 `dart:io exit(0)` 行为。
  Future<void> closeSelf() async {
    if (_isChildWindow) {
      await Get.find<MultiWindowService>().closeSelf();
      return;
    }
    exit(0);
  }
```

补 import：
`package:simple_live_app/app/multi_window/window_args.dart`、
`package:simple_live_app/app/multi_window/multi_window_service.dart`。

- [ ] **Step 4: 改造 `live_room_controller` 的音量滑块与 `exit`**

修改 `simple_live_app/lib/modules/live_room/live_room_controller.dart`。

`showVolumeSlider` 中，把 Slider 的

```dart
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
```

改为

```dart
                value: currentVolume.value,
                onChanged: (newValue) {
                  setVolume(newValue);
                },
```

把 `setAutoExit()` 及其余位置的 `exit(0);` 全部替换为

```dart
        await closeSelf();
```

（共 2 处，行号约 189 与 202）。

- [ ] **Step 5: 运行测试确认通过**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: PASS。

- [ ] **Step 6: 静态检查**

Run: `cd simple_live_app && flutter analyze lib/modules/live_room/`
Expected: 无 error。若报 `currentVolume` 未定义，检查是否加在了正确的 mixin 层级。

- [ ] **Step 7: 提交**

```bash
git add simple_live_app/lib/modules/live_room/player/player_controller.dart simple_live_app/lib/modules/live_room/live_room_controller.dart simple_live_app/test/window_args_test.dart
git commit -m "fix: 子窗口定时关闭不再终止整个进程

live_room_controller 的 exit(0) 解析到 dart:io 的 exit，单窗口下等价于
关窗口，多开下任一子窗口定时器到期会杀掉主窗口和所有其他窗口。
改为 closeSelf()：子窗口只关自己。

同时子窗口音量改为内存独立值，不再覆盖全局设置。"
```

---

### Task 7: 子窗口关闭时回收播放器

窗口销毁时 engine 直接死掉，GetX 的 `onClose` 不保证执行。播放器若未
stop/dispose 就消失，Windows 上会因 mpv 渲染线程与纹理注销竞争而
`0xc0000005` 闪退（commit `067833b`）。

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/player/player_controller.dart`
- Modify: `simple_live_app/lib/app/multi_window/child_live_room_app.dart`
- Modify: `simple_live_app/test/window_args_test.dart`

**Interfaces:**
- Consumes: Task 4 的 `ChildLiveRoomApp`；Task 3 的 `MultiWindowService.isChildWindow`
- Produces: `PlayerController.teardown()` — 幂等的资源回收，`onClose` 与窗口关闭回调共用

- [ ] **Step 1: 写失败测试**

在 `simple_live_app/test/window_args_test.dart` 末尾追加：

```dart
  group('子窗口关闭时回收播放器', () {
    test('PlayerController 提供幂等 teardown，顺序为 stop 后 dispose', () {
      final source = File(
        'lib/modules/live_room/player/player_controller.dart',
      ).readAsStringSync();
      expect(source, contains('teardown()'));
      expect(source, contains('_tornDown'));
      final stop = source.indexOf('await player.stop()');
      final dispose = source.indexOf('await player.dispose()');
      expect(stop, greaterThan(-1));
      expect(dispose, greaterThan(-1));
      // stop 必须排在 dispose 之前，否则 Windows 上 0xc0000005 闪退
      expect(stop, lessThan(dispose));
    });
  });
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: FAIL — `contains('teardown()')` 不满足。

- [ ] **Step 3: 把 `onClose` 抽成幂等的 `teardown`**

修改 `simple_live_app/lib/modules/live_room/player/player_controller.dart`。
把现有的 `onClose` 整体替换为：

```dart
  bool _tornDown = false;

  /// 回收播放器与系统资源
  ///
  /// 幂等：子窗口关闭时由 WindowListener 显式调用，GetX 的 onClose 随后也会触发，
  /// 两者都会走到这里，必须避免重复 dispose。
  Future<void> teardown() async {
    if (_tornDown) return;
    _tornDown = true;
    Log.w("播放器关闭");
    if (smallWindowState.value) {
      exitSmallWindow();
    }
    disposeStream();
    disposeDanmakuController();
    await resetSystem();
    // 先停止播放并等待 mpv 渲染线程空闲，再释放播放器。
    // 否则 Windows 上 dispose 注销纹理时会与仍在渲染的 mpv 线程竞争，
    // 导致 flutter_windows.dll 访问冲突（0xc0000005）闪退
    try {
      await player.stop();
    } catch (e) {
      Log.logPrint(e);
    }
    await player.dispose();
  }

  @override
  void onClose() async {
    await teardown();
    super.onClose();
  }
```

- [ ] **Step 4: 在 `ChildLiveRoomApp` 拦截窗口关闭**

把 `ChildLiveRoomApp` 从 `StatelessWidget` 改为有状态组件，
以持有 `WindowListener`。修改 `child_live_room_app.dart`：

```dart
class ChildLiveRoomApp extends StatefulWidget {
  const ChildLiveRoomApp({super.key});

  @override
  State<ChildLiveRoomApp> createState() => _ChildLiveRoomAppState();
}

class _ChildLiveRoomAppState extends State<ChildLiveRoomApp>
    with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // 拦截关闭，先回收播放器再真正关窗
    windowManager.setPreventClose(true);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // 窗口销毁时 engine 会直接死掉，GetX 的 onClose 不保证执行，
    // 必须在此显式回收播放器，否则 Windows 上 mpv 线程与纹理注销竞争会闪退
    if (Get.isRegistered<LiveRoomController>()) {
      await Get.find<LiveRoomController>().teardown();
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    // ... 与原 StatelessWidget 版本完全相同的 build 内容
  }
}
```

补 import：`package:window_manager/window_manager.dart`。

- [ ] **Step 5: 运行测试确认通过**

Run: `cd simple_live_app && flutter test test/window_args_test.dart`
Expected: PASS。

- [ ] **Step 6: 静态检查**

Run: `cd simple_live_app && flutter analyze lib/`
Expected: 无 error。

- [ ] **Step 7: 提交**

```bash
git add simple_live_app/lib/modules/live_room/player/player_controller.dart simple_live_app/lib/app/multi_window/child_live_room_app.dart simple_live_app/test/window_args_test.dart
git commit -m "fix: 子窗口关闭时先回收播放器再销毁窗口

窗口销毁时 engine 直接结束，GetX onClose 不保证执行。用幂等的 teardown
在 WindowListener.onWindowClose 中显式回收，保持 stop 先于 dispose 的顺序，
避免 Windows 0xc0000005 闪退。"
```

---

### Task 8: 编译验证与手工验证清单

**Files:**
- 无代码改动，除非前序 task 暴露编译错误

**Interfaces:**
- Consumes: Task 1-7 全部
- Produces: 可构建的 macOS / Windows 产物

- [ ] **Step 1: macOS 构建**

Run: `cd simple_live_app && flutter build macos`
Expected: 构建成功。若报 `No such module 'desktop_multi_window'`，回到 Task 2 Step 3
重跑 `pod install`。若报其它模块缺失，同样是 pod 未安装完整。

- [ ] **Step 2: Windows 构建**

Run: `cd simple_live_app && flutter build windows`
Expected: 构建成功。若报 `desktop_multi_window_plugin.h` 找不到，检查
`windows/runner/flutter_window.cpp` 的 include 是否已加。

- [ ] **Step 3: 静态检查全量**

Run: `cd simple_live_app && flutter analyze`
Expected: 无 error。

- [ ] **Step 4: 单元测试全量**

Run: `cd simple_live_app && flutter test`
Expected: 全部通过。

- [ ] **Step 5: 确认未混入无关改动**

Run: `git status --short`
Expected: 只剩 spec §7.7 列出的与本功能无关的本地漂移
（`Podfile`、`Podfile.lock`、`pbxproj`、`xcscheme`、
`AppDelegate.swift`、iOS `AppFrameworkInfo.plist`、Linux registrant）。
若发现其他文件被意外改动，逐个核对来源后决定是否补提交。

- [ ] **Step 6: 交付手工验证清单给负责人**

把 spec §8 的 10 条手工验证项交给负责人在真机上执行，重点是：

- 第 2 条（移动端行为不变）
- 第 6 条（关闭子窗口不崩溃）
- 第 9 条（子窗口定时关闭不影响其他窗口）

这些无法用自动化测试覆盖，需要真机确认。

---

## 自检记录

- **spec 覆盖**：§1 目标 → Task 4/5；§2.2 播放器独立 → 无需改动（Task 6 只隔离音量）；
  §2.3 插件注册 → Task 2；§2.4 SyncService/窗口句柄/退出语义 → Task 3/4；
  §2.5 `exit(0)` → Task 6；§3 架构 → Task 4；§4 查重 → Task 3；§5.3 回收 → Task 7；
  §5.5 测试替换 → Task 1。
- **一致性**：`WindowArgs.decode` 在 Task 1 定义为工厂，Task 3/4 使用 `WindowArgs.decode(x)`
  与 `WindowArgs(siteId:, roomId:, title:)`，签名一致。`MultiWindowService` 的
  `openRoom` / `closeSelf` / `setupSelfWindow` / `registerChildWindowHandler` 在 Task 3 定义，
  Task 4/5/6/7 调用名一致。
- **比例**：计划 8 个 task，约 470 行，对应 spec 的 9 节。没有把实现代码抄成计划——
  代码块只出现在需要精确定义接口与测试断言的地方。