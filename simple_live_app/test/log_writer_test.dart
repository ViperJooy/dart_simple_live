import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    Log.logFileWriter = null;
  });

  test('关闭日志写入会等待文件句柄释放', () async {
    final writer = _BlockingLogFileWriter();
    Log.logFileWriter = writer;
    addTearDown(writer.release);

    var disposed = false;
    final disposeFuture = Future.sync(() => Log.disposeWriter())
        .whenComplete(() => disposed = true);
    await Future<void>.delayed(Duration.zero);

    // 文件句柄尚未释放时，清空日志不能继续，否则 Windows 会删除失败。
    expect(disposed, isFalse);

    writer.release();
    await disposeFuture;
    expect(writer.closed, isTrue);
  });
}

class _BlockingLogFileWriter extends LogFileWriter {
  final Completer<void> _closeCompleter = Completer<void>();
  bool closed = false;

  @override
  void initFile() {}

  @override
  Future<void> close() async {
    await _closeCompleter.future;
    closed = true;
  }

  void release() {
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }
}
