import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'settings_store.dart';
import '../utils/bounded_log_queue.dart';
import '../utils/log_rotation.dart';

/// 本地崩溃日志：设置「崩溃日志上报」开启时，
/// 未捕获异常（Flutter 构建错误 + 平台异步错误）写入
/// 文档目录/crash_logs/crash-<时间>.log，便于用户反馈时附上排查。
/// （云端 Sentry 上报属后续版本，见设置页说明）
class CrashLogger {
  CrashLogger._();

  static bool _installed = false;
  static bool _enabled = false;

  static void init() {
    if (_installed) return;
    _installed = true;
    // 启动时读取开关（异步，不影响首帧）
    SettingsStore.instance.load().then(
      (s) => _enabled = s['crashReport'] == true,
    );

    // flutter_test 环境不接管 onError（测试绑定自行管理，接管会破坏断言）
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;

    FlutterError.onError = (details) {
      FlutterError.presentError(details); // 保留默认控制台输出
      _log(
        'FlutterError: ${details.exceptionAsString()}\n${details.stack ?? ''}',
      );
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _log('Uncaught: $error\n$stack');
      return false; // 继续走默认处理
    };
  }

  /// 设置页开关联动
  static void setEnabled(bool v) => _enabled = v;

  static const _maxCrashFiles = 20;
  static const _maxFileBytes = 512 * 1024;
  static File? _active;
  static int _sequence = 0;
  static final _queue = BoundedLogQueue(_writeBatch);

  static void _log(String content) {
    if (!_enabled || kIsWeb) return;
    _queue.add(
      '${DateTime.now().toIso8601String()}\n${capLogRecord(content)}\n\n',
    );
  }

  static Future<void> _writeBatch(String batch) async {
    final dir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${dir.path}/crash_logs');
    await logDir.create(recursive: true);
    // UTF8 length is bounded to one batch, never a whole backlog.
    final bytes = utf8.encode(batch);
    if (_active == null ||
        !await _active!.exists() ||
        await _active!.length() + bytes.length > _maxFileBytes) {
      _active = File(
        '${logDir.path}/crash-'
        '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}.log',
      );
      await _active!.create();
      // Prune at rollover, not when a potentially endless storm becomes idle.
      await _pruneOld(logDir);
    }
    await appendBoundedLog(_active!, batch, maxBytes: _maxFileBytes);
  }

  @visibleForTesting
  static void logForTest(String content) => _log(content);
  @visibleForTesting
  static Future<void> flushForTest() => _queue.flush();
  @visibleForTesting
  static int get pendingBytesForTest => _queue.pendingBytes;

  /// 仅保留最近 [_maxCrashFiles] 个崩溃文件（文件名毫秒时间戳，字典序即时间序）
  static Future<void> _pruneOld(Directory dir) async {
    try {
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.log'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      while (files.length > _maxCrashFiles) {
        await files.removeAt(0).delete();
      }
    } catch (_) {}
  }
}
