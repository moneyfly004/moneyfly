import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'settings_store.dart';

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
    SettingsStore.instance.load().then((s) => _enabled = s['crashReport'] == true);

    // flutter_test 环境不接管 onError（测试绑定自行管理，接管会破坏断言）
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;

    FlutterError.onError = (details) {
      FlutterError.presentError(details); // 保留默认控制台输出
      _log('FlutterError: ${details.exceptionAsString()}\n${details.stack ?? ''}');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _log('Uncaught: $error\n$stack');
      return false; // 继续走默认处理
    };
  }

  /// 设置页开关联动
  static void setEnabled(bool v) => _enabled = v;

  static final List<String> _pending = [];
  static Future<void>? _flushing;

  /// 崩溃日志目录保留的最大文件数，防止无限堆积
  static const _maxCrashFiles = 20;

  /// 待写缓冲上限：崩溃风暴 + 目录不可用时，_pending 会无界增长（内存）。
  static const _maxPending = 100;

  static void _log(String content) {
    if (!_enabled || kIsWeb) return;
    if (_pending.length >= _maxPending) _pending.removeAt(0); // 丢最旧，保住上限
    _pending.add('${DateTime.now().toIso8601String()}\n$content\n\n');
    _flushing ??= _drain();
  }

  /// 把待写日志串行落盘。写盘期间若有新崩溃追加，末尾同步判断后立即
  /// 接续下一轮（判断与清空 `_flushing` 之间无 await，不会漏掉并发日志）。
  static Future<void> _drain() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/crash_logs');
      if (!logDir.existsSync()) logDir.createSync(recursive: true);
      final file = File('${logDir.path}/crash-${DateTime.now().millisecondsSinceEpoch}.log');
      while (_pending.isNotEmpty) {
        final batch = List<String>.of(_pending);
        _pending.clear();
        for (final line in batch) {
          await file.writeAsString(line, mode: FileMode.append);
        }
      }
      await _pruneOld(logDir);
    } catch (_) {
      // 日志失败不产生新的崩溃
    }
    if (_pending.isNotEmpty) {
      // 失败重排必须**带延迟**：旧实现在第一步 getApplicationDocumentsDirectory()
      // 就抛错时，会立刻重新入队 _drain → 无退避空转（崩溃循环 + 目录不可用
      // 时 CPU 打满、_pending 持续增长）。延迟后再试，且由 _flushing 去重。
      await Future.delayed(const Duration(seconds: 5));
      _flushing = _drain();
    } else {
      _flushing = null;
    }
  }

  /// 仅保留最近 [_maxCrashFiles] 个崩溃文件（文件名毫秒时间戳，字典序即时间序）
  static Future<void> _pruneOld(Directory dir) async {
    try {
      final files = dir
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
