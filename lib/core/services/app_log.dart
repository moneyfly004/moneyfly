import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 应用诊断日志：记录连接状态变化、内核事件、错误、闪退等关键事件。
/// 所有日志写入 app_log.txt，设置页可导出给开发者排查问题。
class AppLog {
  AppLog._();

  static File? _file;
  static bool _rotating = false;
  static const _maxSize = 512 * 1024; // 512KB

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
  static Future<String> read() async {
    final f = await _resolve();
    if (f == null || !f.existsSync()) return '';
    return f.readAsString();
  }

  /// 清空日志
  static Future<void> clear() async {
    final f = await _resolve();
    if (f != null && f.existsSync()) await f.writeAsString('');
  }

  /// 写入一条日志（fire-and-forget，不阻塞调用方）
  static void log(String tag, String message) {
    if (kIsWeb) return;
    _writeAsync('[${DateTime.now().toIso8601String()}] [$tag] $message\n');
  }

  /// 连接状态变化
  static void conn(String message) => log('CONN', message);

  /// 内核事件
  static void kernel(String message) => log('KERNEL', message);

  /// 错误
  static void error(String message) => log('ERROR', message);

  /// 网络事件
  static void net(String message) => log('NET', message);

  static void _writeAsync(String line) {
    unawaited(() async {
      try {
        final f = await _resolve();
        if (f == null) return;
        await f.writeAsString(line, mode: FileMode.append, flush: false);
        if (!_rotating && await f.length() > _maxSize) {
          _rotating = true;
          try {
            final content = await f.readAsString();
            await f.writeAsString(content.substring(content.length ~/ 2), flush: true);
          } finally {
            _rotating = false;
          }
        }
      } catch (_) {}
    }());
  }
}
