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