import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 应用诊断日志：记录连接状态变化、内核事件、错误、闪退等关键事件。
/// 所有日志写入 app_log.txt，设置页可导出给开发者排查问题。
///
/// 写路径串行化：所有 append 与旋转进同一条 future 链，杜绝并发
/// fire-and-forget 的「读半份改写」竞态（丢行/截断内容互相污染）。
class AppLog {
  AppLog._();

  static File? _file;
  static const _maxSize = 512 * 1024; // 512KB

  /// 串行写队列：每条日志/旋转依次执行
  static Future<void> _writeQueue = Future.value();

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

  /// 清空日志（入队执行，避免与在写 append 交错）
  static Future<void> clear() {
    final job = _writeQueue.then((_) async {
      final f = await _resolve();
      if (f != null && f.existsSync()) {
        await f.writeAsString('');
      }
    });
    _writeQueue = job.catchError((_) {});
    return job;
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
    final job = _writeQueue.then((_) async {
      try {
        final f = await _resolve();
        if (f == null) return;
        await f.writeAsString(line, mode: FileMode.append, flush: false);
        // 超 512KB：保留后半（按行旋转，在队列内执行无并发交错）
        if (await f.length() > _maxSize) {
          final content = await f.readAsString();
          await f.writeAsString(_keepSecondHalf(content), flush: true);
        }
      } catch (_) {}
    });
    _writeQueue = job.catchError((_) {});
  }

  /// 取后半段日志用于旋转。找中点后的第一个换行再截断，保证：
  /// - 不在半个 UTF-16 代理对（emoji）中间切，避免写出损坏字符；
  /// - 不切断一行，首行始终完整。
  static String _keepSecondHalf(String content) {
    final nl = content.indexOf('\n', content.length ~/ 2);
    if (nl < 0 || nl + 1 >= content.length) return content; // 无换行/已到末尾：不截断
    return content.substring(nl + 1);
  }
}
