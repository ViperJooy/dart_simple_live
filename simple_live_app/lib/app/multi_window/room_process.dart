import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/child_live_room_app.dart';
import 'package:simple_live_app/app/multi_window/multi_window_service.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 房间窗口的进程模式
///
/// 为什么不用 desktop_multi_window 的同进程多 engine 方案：
/// 同进程子窗口与主窗口共享一个 Win32 消息循环，在这台机器上
/// （Windows 11 Insider 26300）输入事件进了 flutter_windows.dll 却
/// 到不了 Dart 层，主窗口点击完全失灵（卡死态 dump 显示无线程阻塞，
/// 属 engine 输入路由层面问题）。独立进程各有消息循环与 engine，
/// Windows 原生调度，所有同进程多窗口问题一次性绕开。
///
/// 数据：房间进程不能打开 Hive box（.lock 文件锁被主进程独占），
/// 启动时读主进程写好的快照文件，写操作落成 JSON 文件由主进程
/// 轮询应用（见 [RoomProcessStore]）。

/// 房间进程启动参数
///
/// 命令行：simple_live_app.exe --room <siteId> <roomId> <snapshotPath>
class RoomProcessArgs {
  final String siteId;
  final String roomId;
  final String snapshotPath;

  const RoomProcessArgs(this.siteId, this.roomId, this.snapshotPath);

  static RoomProcessArgs? tryParse(List<String> args) {
    if (!Platform.isWindows) return null;
    if (args.length >= 4 && args[0] == '--room') {
      return RoomProcessArgs(args[1], args[2], args[3]);
    }
    return null;
  }
}

/// 主窗口侧：点击直播间时启动独立进程
class RoomProcessLauncher {
  static Future<void> openRoom(WindowArgs args) async {
    final snapshotPath = await RoomProcessStore.writeSnapshot(args);
    final exe = Platform.resolvedExecutable;
    Log.logPrint(
        '[RoomProc] 启动房间进程: ${args.siteId}/${args.roomId}');
    await Process.start(
      exe,
      ['--room', args.siteId, args.roomId, snapshotPath],
      mode: ProcessStartMode.detached,
    );
  }
}

/// 房间进程入口（main() 检测到 --room 参数后调用）
Future<void> runRoomProcess(RoomProcessArgs args) async {
  // 确保日志写文件
  if (Log.logFileWriter == null) Log.initWriter();
  Log.logPrint('[RoomProc] 启动: ${args.siteId}/${args.roomId} pid=$pid');

  MediaKit.ensureInitialized();

  final snapshot = await RoomProcessStore.readSnapshot(args.snapshotPath);
  final title = (snapshot['title'] as String?) ?? '';

  // 房间页代码通过 MultiWindowService.isChildWindow 判断自己是房间窗口
  // （windowId 为空表示进程模式，没有窗口通道）
  Get.put(MultiWindowService(
    windowId: '',
    windowArgs:
        WindowArgs(siteId: args.siteId, roomId: args.roomId, title: title),
  ));

  await initChildServices(
    snapshot: snapshot,
    invoker: RoomProcessStore.writeInvoker,
  );
  Log.logPrint('[RoomProc] services ready');

  await windowManager.ensureInitialized();
  windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: childWindowSizeFor(args.siteId),
      center: true,
      title: title.isEmpty ? 'Simple Live' : '$title - Simple Live',
      minimumSize: const Size(280, 280),
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  Log.logPrint('[RoomProc] runApp');

  runApp(const ChildLiveRoomApp());

  // 与 runChildWindow 同理：控制器必须在首帧之后创建，否则 onInit 里的
  // SmartDialog.showLoading 会触发 LateInitializationError(loadingWidget)
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Get.put<LiveRoomController>(LiveRoomController(
      pSite: Sites.allSites[args.siteId]!,
      pRoomId: args.roomId,
    ));
  });
}

/// 进程间数据投递：快照文件 + 写操作文件
///
/// 目录：%TEMP%/simple_live_rooms/
///   snapshot_<uuid>.json  主进程写给房间进程的数据快照（读完即删）
///   writes/<ts>_<uuid>.json  房间进程的写操作（主进程轮询应用后删除）
class RoomProcessStore {
  static String _rootDir() {
    final temp = Platform.environment['TEMP'] ??
        Platform.environment['TMP'] ??
        Directory.systemTemp.path;
    return p.join(temp, 'simple_live_rooms');
  }

  static Future<Directory> _ensureDir([String sub = '']) async {
    final dir = Directory(p.join(_rootDir(), sub));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 主进程：为即将启动的房间进程写数据快照，返回文件路径
  static Future<String> writeSnapshot(WindowArgs args) async {
    final dir = await _ensureDir();
    final path = p.join(dir.path, 'snapshot_${const Uuid().v4()}.json');
    final payload = buildDataSnapshot();
    payload['title'] = args.title;
    await File(path).writeAsString(jsonEncode(payload));
    return path;
  }

  /// 房间进程：读数据快照（带重试），读完删除
  static Future<Map<dynamic, dynamic>> readSnapshot(String path) async {
    for (var i = 0; i < 20; i++) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final map = jsonDecode(await file.readAsString()) as Map;
          await file.delete();
          return map;
        }
      } catch (e) {
        Log.logPrint('[RoomProc] 读取快照失败(第${i + 1}次): $e');
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    throw Exception('读取数据快照失败: $path');
  }

  /// 房间进程：写操作落成一个 JSON 文件，主进程轮询应用。
  /// 一个操作一个文件（文件名即顺序），避免追加写与轮询删除的竞争。
  static Future<dynamic> writeInvoker(String method,
      [dynamic arguments]) async {
    try {
      final dir = await _ensureDir('writes');
      final name =
          '${DateTime.now().millisecondsSinceEpoch}_${const Uuid().v4()}.json';
      await File(p.join(dir.path, name))
          .writeAsString(jsonEncode({'m': method, 'a': arguments}));
    } catch (e) {
      Log.logPrint('[RoomProc] 写操作投递失败 $method: $e');
    }
    return true;
  }

  static Timer? _applier;

  /// 主进程：启动写操作轮询（2 秒一轮，启动时先清一次积压）
  static void startWriteApplier() {
    _applyPendingWrites();
    _applier ??= Timer.periodic(
        const Duration(seconds: 2), (_) => _applyPendingWrites());
  }

  static Future<void> _applyPendingWrites() async {
    try {
      final dir = Directory(p.join(_rootDir(), 'writes'));
      if (!await dir.exists()) return;
      final files = (await dir
              .list()
              .where((f) => f is File && f.path.endsWith('.json'))
              .toList())
          .cast<File>()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        try {
          final op = jsonDecode(await file.readAsString());
          await handleChildDataRequest(op['m'] as String, op['a']);
          await file.delete();
        } catch (e) {
          Log.logPrint('[RoomProc] 应用写操作失败 ${file.path}: $e');
          // 写了一半的坏文件下一轮重试；超过 1 分钟还没好说明写入方已死，删掉
          final stat = await file.stat();
          if (DateTime.now().difference(stat.modified).inMinutes > 1) {
            await file.delete();
          }
        }
      }
    } catch (e) {
      Log.logPrint('[RoomProc] 写操作扫描失败: $e');
    }
  }

  /// 主进程启动时清理遗留的快照文件（房间进程没来得及读就崩溃的情况）
  static Future<void> cleanupOldSnapshots() async {
    try {
      final dir = Directory(_rootDir());
      if (!await dir.exists()) return;
      await for (final f in dir.list()) {
        if (f is File && p.basename(f.path).startsWith('snapshot_')) {
          final stat = await f.stat();
          if (DateTime.now().difference(stat.modified).inHours >= 1) {
            await f.delete();
          }
        }
      }
    } catch (_) {}
  }
}
