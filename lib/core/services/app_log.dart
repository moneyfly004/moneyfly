import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/log_rotation.dart';
import '../utils/bounded_log_queue.dart';

/// 应用诊断日志：记录连接状态变化、内核事件、错误、闪退等关键事件。
/// 所有日志写入 app_log.txt，设置页可导出给开发者排查问题。
///
/// 写路径经 [BoundedLogQueue] 串行化：append 与旋转进同一条队列，杜绝并发
/// fire-and-forget 的「读半份改写」竞态（丢行/截断内容互相污染）。
class AppLog {
  AppLog._();

  static File? _file;
  static const _maxSize = 512 * 1024; // 512KB

  static final BoundedLogQueue _queue = BoundedLogQueue((batch) async {
    final f = await _resolve();
    if (f != null) await appendBoundedLog(f, batch, maxBytes: _maxSize);
  });

  static Future<File?> _resolve() async {
    if (_file != null) return _file;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/app_log.txt');
      return _file;
    } catch (_) {
      return null;
    }
  }

  /// 获取日志文件路径（设置页导出用）
  static Future<String?> get filePath async {
    final f = await _resolve();
    return f?.path;
  }

  /// 获取日志内容（设置页预览用）
  static Future<String> read() => _queue.run(() async {
    final f = await _resolve();
    return f == null ? '' : readLogTail(f);
  });

  /// 清空日志（入队执行，避免与在写 append 交错）
  static Future<void> clear() {
    return _queue.run(() async {
      final f = await _resolve();
      if (f != null && f.existsSync()) {
        await f.writeAsString('');
      }
    });
  }

  /// 写入一条日志（fire-and-forget，不阻塞调用方）
  static void log(String tag, String message) {
    if (kIsWeb) return;
    _writeAsync(
      '[${DateTime.now().toIso8601String()}] [${capLogRecord(tag, maxBytes: 1024)}] ${capLogRecord(message)}\n',
    );
  }

  /// 连接状态变化
  static void conn(String message) => log('CONN', message);

  /// 内核事件
  static void kernel(String message) => log('KERNEL', message);

  /// 错误
  static void error(String message) => log('ERROR', message);

  /// 网络事件
  static void net(String message) => log('NET', message);

  static void _writeAsync(String line) => _queue.add(line);
}
