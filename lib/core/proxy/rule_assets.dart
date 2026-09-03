import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 内置规则集落盘器（geoip-cn / geosite-cn 的 .srs）。
///
/// 智能模式(Rule)需要 CN 分流规则集。这些文件随安装包打包在
/// assets/rules/ 下；必须落到「内核进程可读的绝对路径」并以 local 规则集
/// 方式引用 —— 否则配置会回退到 GitHub raw 远程下载，国内网络必超时，
/// 表现为「内核启动失败：geosite-cn ... context deadline exceeded」。
///
/// - 桌面端(CLI)：落到 ProxyCoreCli.workDir（内核子进程读同一路径）
/// - Android：落到 app 私有目录（VpnService 同 UID 可读），用 path_provider 取
class RuleAssets {
  RuleAssets._();

  static const files = ['geoip-cn.srs', 'geosite-cn.srs'];

  /// 落盘并返回目录绝对路径；失败返回 null（调用方回退远程规则集）。
  /// [preferDir] 指定目标目录（桌面端传内核 workDir）；为空时用 app 支持目录。
  static Future<String?> materialize({String? preferDir}) async {
    try {
      final dirPath = preferDir ?? await _defaultDir();
      if (dirPath == null) return null;
      final dir = Directory(dirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      for (final file in files) {
        final target = File('${dir.path}/$file');
        // 幂等：已存在且非空则跳过（避免每次连接重复写盘）
        if (target.existsSync() && target.lengthSync() > 0) continue;
        final data = await rootBundle.load('assets/rules/$file');
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      return dir.path;
    } catch (e) {
      debugPrint('RuleAssets.materialize 失败（将回退远程规则集）: $e');
      return null;
    }
  }

  static Future<String?> _defaultDir() async {
    try {
      final base = await getApplicationSupportDirectory();
      return '${base.path}/rules';
    } catch (_) {
      return null;
    }
  }
}
