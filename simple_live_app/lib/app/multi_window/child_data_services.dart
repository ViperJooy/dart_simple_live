import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 向主窗口进程发起数据请求的通道
///
/// 同进程多窗口（macOS）：包装 WindowController.invokeMethod 走窗口通道；
/// 独立进程房间窗口（Windows）：包装 RoomProcessStore 的文件投递。
typedef MainWindowInvoker = Future<dynamic> Function(String method,
    [dynamic arguments]);

/// 查找主窗口控制器（带重试）
///
/// 子窗口的数据请求都通过主窗口转发，启动时先找到它。
Future<WindowController> findMainWindowController() async {
  for (var i = 0; i < 25; i++) {
    try {
      final windows = await WindowController.getAll();
      for (final controller in windows) {
        if (WindowArgs.decode(controller.arguments).isMainWindow) {
          return controller;
        }
      }
    } catch (e) {
      Log.logPrint('[MW] child: 枚举窗口失败(第${i + 1}次): $e');
    }
    await Future.delayed(const Duration(milliseconds: 200));
  }
  throw Exception('找不到主窗口');
}

/// 从主窗口拉取数据快照（带重试）
Future<Map<dynamic, dynamic>> fetchMainWindowSnapshot(
    WindowController mainWindow) async {
  for (var i = 0; i < 10; i++) {
    try {
      final result = await mainWindow.invokeMethod('mw_snapshot');
      if (result is Map) return result;
    } catch (e) {
      Log.logPrint('[MW] child: 获取主窗口数据快照失败(第${i + 1}次): $e');
    }
    await Future.delayed(const Duration(milliseconds: 300));
  }
  throw Exception('无法从主窗口获取数据快照');
}

/// 子窗口的 LocalStorageService
///
/// 为什么不能直接 Hive.openBox：子窗口（同进程 engine 或独立进程）都不是
/// Hive 锁的持有者，主窗口进程独占 .lock。Windows 上 LockFileEx 按句柄判定
/// 冲突，第二个持有者加锁会永久阻塞 —— 表现为点开直播间卡死。
///
/// 所以子窗口改为：启动时从主窗口拉一份快照做本地读取，
/// 写操作更新内存后经 [invoke] 转发给主窗口进程落盘。
class ChildLocalStorageService extends LocalStorageService {
  final MainWindowInvoker invoke;
  final Map<dynamic, dynamic> _settings;
  final Set<String> _shield;

  ChildLocalStorageService(this.invoke, Map<dynamic, dynamic> snapshot)
      : _settings = Map<dynamic, dynamic>.from(
            (snapshot['settings'] as Map?) ?? {}),
        _shield = Set<String>.from(
            (snapshot['shield'] as List?)?.cast<String>() ?? []);

  @override
  Future init() async {
    // 数据已在构造时注入，无需打开 Hive box
  }

  @override
  T getValue<T>(dynamic key, T defaultValue) {
    try {
      var value = (_settings[key] as T?) ?? defaultValue;
      Log.d("Get LocalStorage：$key\r\n$value");
      return value;
    } catch (e) {
      Log.logPrint(e);
      return defaultValue;
    }
  }

  @override
  Future setValue<T>(dynamic key, T value) async {
    Log.d("Set LocalStorage：$key\r\n$value");
    _settings[key] = value;
    return await invoke('mw_set_value', {
      'key': key,
      'value': value,
    });
  }

  @override
  Future removeValue<T>(dynamic key) async {
    Log.d("Remove LocalStorage：$key");
    _settings.remove(key);
    return await invoke('mw_remove_value', key);
  }

  @override
  Set<String> getShieldList() {
    return Set.of(_shield);
  }

  @override
  Future addShield(String value) async {
    _shield.add(value);
    await invoke('mw_shield_add', value);
  }

  @override
  Future removeShield(String value) async {
    _shield.remove(value);
    await invoke('mw_shield_remove', value);
  }

  @override
  Future clearShield() async {
    _shield.clear();
    await invoke('mw_shield_clear');
  }
}

/// 子窗口的 DBService
///
/// 与 ChildLocalStorageService 同理：关注/历史数据来自主窗口快照，
/// 写操作更新内存后转发给主窗口进程落盘。
class ChildDBService extends DBService {
  final MainWindowInvoker invoke;
  final Map<String, FollowUser> _follows;
  final Map<String, FollowUserTag> _tags;
  final Map<String, History> _histories;

  ChildDBService(this.invoke, Map<dynamic, dynamic> snapshot)
      : _follows = {
          for (final e in (snapshot['follows'] as List?) ?? [])
            (e as Map)['id'] as String: FollowUser.fromJson(
                Map<String, dynamic>.from(e)),
        },
        _tags = {
          for (final e in (snapshot['tags'] as List?) ?? [])
            (e as Map)['id'] as String: FollowUserTag.fromJson(
                Map<String, dynamic>.from(e)),
        },
        _histories = {
          for (final e in (snapshot['histories'] as List?) ?? [])
            (e as Map)['id'] as String: History.fromJson(
                Map<String, dynamic>.from(e)),
        };

  @override
  Future init() async {
    // 数据已在构造时注入，无需打开 Hive box
  }

  @override
  bool getFollowExist(String id) {
    return _follows.containsKey(id);
  }

  @override
  List<FollowUser> getFollowList() {
    return _follows.values.toList();
  }

  @override
  Future addFollow(FollowUser follow) async {
    _follows[follow.id] = follow;
    await invoke('mw_add_follow', follow.toJson());
  }

  @override
  Future deleteFollow(String id) async {
    _follows.remove(id);
    await invoke('mw_delete_follow', id);
  }

  @override
  History? getHistory(String id) {
    return _histories[id];
  }

  @override
  Future addOrUpdateHistory(History history) async {
    _histories[history.id] = history;
    await invoke('mw_add_history', history.toJson());
  }

  @override
  List<FollowUserTag> getFollowTagList() {
    return _tags.values.toList();
  }

  @override
  bool getFollowTagExist(String id) {
    return _tags.containsKey(id);
  }

  @override
  FollowUserTag? getFollowTag(String tag) {
    for (final item in _tags.values) {
      if (item.tag == tag) return item;
    }
    return null;
  }

  @override
  Future<FollowUserTag> addFollowTag(String tag) async {
    if (getFollowTagExistByTag(tag) && tag.length > 8) {
      return getFollowTag(tag)!;
    }
    final String uniqueId = uuid.v4();
    final followUserTag = FollowUserTag(id: uniqueId, tag: tag, userId: []);
    _tags[uniqueId] = followUserTag;
    await invoke('mw_add_follow_tag', followUserTag.toJson());
    return followUserTag;
  }

  @override
  Future updateFollowTag(FollowUserTag followTag) async {
    _tags[followTag.id] = followTag;
    await invoke('mw_update_follow_tag', followTag.toJson());
  }

  @override
  Future deleteFollowTag(String id) async {
    _tags.remove(id);
    await invoke('mw_delete_follow_tag', id);
  }
}
