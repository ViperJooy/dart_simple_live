#include "flutter_window.h"

#include <commctrl.h>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"

#pragma comment(lib, "comctl32.lib")

namespace {

// 诊断：子类化主窗口的 FlutterView HWND，记录送达 Flutter 嵌入层的
// 指针消息（排查多窗口下主窗口输入失灵，排查后移除）。
// 客户区点击的实际接收者是 FlutterView 子窗口，顶层 WndProc 看不到。
LRESULT CALLBACK FlutterViewInputLogSubclassProc(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam,
                                                 UINT_PTR subclass_id,
                                                 DWORD_PTR ref_data) {
  switch (message) {
    case WM_POINTERDOWN:
    case WM_POINTERUP:
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_RBUTTONDOWN:
      DebugLogWindowMessage(hwnd, message, wparam, lparam);
      break;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

}  // namespace

// 子窗口（独立 engine）的白名单插件头，与 generated_plugin_registrant.cc
// 保持一致，仅排除 flutter_inappwebview_windows。
#include <connectivity_plus/connectivity_plus_windows_plugin.h>
#include <dynamic_color/dynamic_color_plugin_c_api.h>
#include <media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h>
#include <media_kit_video/media_kit_video_plugin_c_api.h>
#include <permission_handler_windows/permission_handler_windows_plugin.h>
#include <screen_brightness_windows/screen_brightness_windows_plugin_c_api.h>
#include <screen_retriever_windows/screen_retriever_windows_plugin_c_api.h>
#include <share_plus/share_plus_windows_plugin_c_api.h>
#include <url_launcher_windows/url_launcher_windows.h>
#include <volume_controller/volume_controller_plugin_c_api.h>
#include <window_manager/window_manager_plugin.h>

// 子窗口引擎的插件注册白名单
//
// 与 RegisterPlugins 的唯一差别：不注册 flutter_inappwebview_windows。
// 该插件注册时就会创建 WinRT DispatcherQueueController 与
// Windows::UI::Composition::Compositor（coremessaging.dll / dcomp.dll），
// 每个子窗口 engine 都重复这段初始化，在 Windows 11 24H2 上会触发
// coremessaging.dll 访问冲突（0xc0000005）导致整个进程闪退；
// 且该插件本身存在 WinRT 对象生命周期缺陷（flutter_inappwebview#2733）。
// 子窗口只有播放页，抖音搜索 / B 站登录等 WebView 页面只在主窗口使用。
static void RegisterChildWindowPlugins(flutter::PluginRegistry* registry) {
  ConnectivityPlusWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ConnectivityPlusWindowsPlugin"));
  DesktopMultiWindowPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("DesktopMultiWindowPlugin"));
  DynamicColorPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("DynamicColorPluginCApi"));
  MediaKitLibsWindowsVideoPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MediaKitLibsWindowsVideoPluginCApi"));
  MediaKitVideoPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MediaKitVideoPluginCApi"));
  PermissionHandlerWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PermissionHandlerWindowsPlugin"));
  // screen_brightness_windows 2.1.2 起 C API 更名为
  // ScreenBrightnessWindowsPluginCApiRegisterWithRegistrar（pluginClass 同步改名），
  // 旧名 ScreenBrightnessWindowsPluginRegisterWithRegistrar 已删除。
  ScreenBrightnessWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ScreenBrightnessWindowsPluginCApi"));
  ScreenRetrieverWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ScreenRetrieverWindowsPluginCApi"));
  SharePlusWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("SharePlusWindowsPluginCApi"));
  UrlLauncherWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UrlLauncherWindows"));
  VolumeControllerPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("VolumeControllerPluginCApi"));
  WindowManagerPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WindowManagerPlugin"));
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool hidden_at_launch)
    : project_(project), hidden_at_launch_(hidden_at_launch) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // desktop_multi_window 为每个子窗口创建独立 engine，method channel 不跨 engine
  // 共享，必须为子窗口单独注册插件，否则子窗口内 media_kit / window_manager 全部失效。
  // 子窗口走白名单注册，排除 flutter_inappwebview_windows（见上方注释）。
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterChildWindowPlugins(registry);
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // 诊断：挂输入日志子类化（排查后移除）
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                    FlutterViewInputLogSubclassProc, 1, 0);

  if (!hidden_at_launch_) {
    flutter_controller_->engine()->SetNextFrameCallback([&]() {
      this->Show();
    });

    // Flutter can complete the first frame before the "show window" callback is
    // registered. The following call ensures a frame is pending to ensure the
    // window is shown. It is a no-op if the first frame hasn't completed yet.
    flutter_controller_->ForceRedraw();
  }
  // 房间进程模式（hidden_at_launch_）：窗口保持隐藏，由 Dart 侧
  // window_manager.waitUntilReadyToShow 设置好尺寸/标题/居中后自行 show，
  // 避免「先默认尺寸闪现、再跳变」的闪烁。

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
