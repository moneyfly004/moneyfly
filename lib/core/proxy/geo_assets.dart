import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 离线 Geo 数据落盘器（geosite.dat / country.mmdb）。
///
/// mihomo 的智能模式(Rule)用 GEOSITE,cn / GEOIP,CN 规则做国内直连，
/// 需要 geosite.dat（域名分类）与 country.mmdb（IP 国家库，默认文件名）。
/// 这些文件随安装包打包在 assets/rules/ 下，必须落到「内核进程可读的
/// 绝对路径」——mihomo 从启动目录(homeDir)加载默认文件名，否则规则匹配
/// 会报 "GEOIP/GEOSITE lookup error"，表现为国内站点无法直连。
///
/// - 桌面端(CLI)：落到 ProxyCoreCli.workDir（内核 -d 指向同一目录）
/// - Android：由原生 Kotlin 直接从 Flutter assets 复制（见 MoneyFlyVpnService），
///   Dart 侧无需落盘（避免 12MB 二进制走 MethodChannel）
class GeoAssets {
  GeoAssets._();

  /// assets 中内置文件名（CI 构建时下载；本地开发用 tool/fetch_geodata.sh）
  static const files = ['geosite.dat', 'country.mmdb'];

  /// 落盘并返回是否全部成功；失败返回 false（调用方降级智能规则为全代理）。
  /// [preferDir] 指定目标目录（桌面端传内核 workDir）；为空时用 app 支持目录。
  static Future<bool> materialize({String? preferDir}) async {
    try {
      final dirPath = preferDir ?? await _defaultDir();
      if (dirPath == null) return false;
      final dir = Directory(dirPath);
      if (!await dir.exists()) await dir.create(recursive: true);
      var ok = true;
      for (final file in files) {
        final target = File('${dir.path}/$file');
        if (await target.exists() && await target.length() > 0) continue;
        try {
          final data = await rootBundle.load('assets/rules/$file');
          await target.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true,
          );
        } catch (e) {
          debugPrint('GeoAssets 复制 $file 失败: $e');
          ok = false;
        }
      }
      return ok;
    } catch (e) {
      debugPrint('GeoAssets.materialize 失败: $e');
      return false;
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
