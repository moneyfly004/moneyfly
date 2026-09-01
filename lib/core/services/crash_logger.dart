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

  static void _log(String content) {
    if (!_enabled || kIsWeb) return;
    final line = '${DateTime.now().toIso8601String()}\n$content\n\n';
    _pending.add(line);
    _flushing ??= _flush().whenComplete(() => _flushing = null);
  }

  static Future<void> _flush() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/crash_logs');
      if (!logDir.existsSync()) logDir.createSync(recursive: true);
      final file = File('${logDir.path}/crash-${DateTime.now().millisecondsSinceEpoch}.log');
      // 合并等待期间的日志，一次性写入
      while (_pending.isNotEmpty) {
        await file.writeAsString(_pending.removeAt(0), mode: FileMode.append);
      }
    } catch (_) {
      // 日志失败不产生新的崩溃
    }
  }
}
