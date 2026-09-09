import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../services/app_log.dart';
import '../services/update_service.dart';

/// 离线 Geo 数据落盘器（geosite.dat / country.mmdb）。
///
/// 数据来源（全部离线、零网络）：
/// 1. **手动更新副本**（设置 → 更新分流数据，[GeoAssets.updatedDir]）——
///    用户在设置页下载的最新版，优先级最高；
/// 2. **内置 assets**（assets/rules/，CI 构建时下载最新打进安装包）——
///    出厂自带，随 App 版本更新。
///
/// mihomo 的智能模式(Rule)用 GEOSITE,cn / GEOIP,CN 规则做国内直连，
/// 需要 geosite.dat（域名分类）与 country.mmdb（IP 国家库，默认文件名）。
/// 这些文件必须落到「内核进程可读的绝对路径」——mihomo 从启动目录(homeDir)
/// 加载默认文件名，否则规则匹配会报 "GEOIP/GEOSITE lookup error"。
///
/// - 桌面端(CLI)：落到 ProxyCoreCli.workDir（内核 -d 指向同一目录）
/// - Android：落到 filesDir/work（MoneyFlyVpnService 同一内核目录；
///   原生层 assets 复制保留为启动兜底，幂等）
///
/// 重要：本类只做本地复制/读取，**绝不联网**。内置/副本缺失属打包异常 →
/// materialize 返回 false，调用方把智能规则降级为全代理（内核启动零网络、
/// 不因缺数据卡顿/失败），用户可在设置页手动更新补回。
class GeoAssets {
  GeoAssets._();

  /// assets 中内置文件名（CI 构建时下载；本地开发用 tool/fetch_geodata.sh）
  static const files = ['geosite.dat', 'country.mmdb'];

  /// 手动更新副本目录（supportDir/geo，设置页下载的最新版放这里）
  static String? _updatedDirPath;

  static Future<String?> updatedDir() async {
    if (_updatedDirPath != null) return _updatedDirPath;
    try {
      final base = await getApplicationSupportDirectory();
      _updatedDirPath = '${base.path}/geo';
      return _updatedDirPath;
    } catch (_) {
      return null;
    }
  }

  /// 读取某个文件的最新数据：手动更新副本 → 内置 assets。
  /// 返回 null 表示两者皆不可用（打包异常）。
  static Future<Uint8List?> readSource(String file) async {
    // 1) 手动更新副本（设置页下载的最新版，优先）
    try {
      final dir = await updatedDir();
      if (dir != null) {
        final f = File('$dir/$file');
        if (await f.exists() && await f.length() > 0) {
          return await f.readAsBytes();
        }
      }
    } catch (_) {}
    // 2) 内置 assets（随 App 打包，构建时下载）
    try {
      final data = await rootBundle.load('assets/rules/$file');
      return data.buffer
          .asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {}
    return null;
  }

  /// 手动更新副本的时间戳（supportDir/geo/.updated.json；无副本返回 null）
  static Future<DateTime?> manualUpdatedAt() async {
    try {
      final dir = await updatedDir();
      if (dir == null) return null;
      final f = File('$dir/.updated.json');
      if (!await f.exists()) return null;
      final m = jsonDecode(await f.readAsString());
      if (m is Map && m['updatedAt'] is String) {
        return DateTime.tryParse(m['updatedAt'] as String);
      }
    } catch (_) {}
    return null;
  }

  /// 记录手动更新成功时间（GeoUpdateService 全部下载成功后调用）
  static Future<void> markUpdatedAt(DateTime at) async {
    try {
      final dir = await updatedDir();
      if (dir == null) return;
      await Directory(dir).create(recursive: true);
      await File('$dir/.updated.json').writeAsString(jsonEncode({
        'updatedAt': at.toIso8601String(),
        'appVersion': UpdateInfo.currentVersion,
      }));
    } catch (_) {}
  }

  /// 落盘并返回是否全部成功；失败返回 false（调用方降级智能规则为全代理）。
  /// [preferDir] 指定目标目录（内核目录：桌面 workDir / Android filesDir/work）。
  ///
  /// 覆盖策略（目标已存在且非空默认跳过，连接不重复写盘；两种情况强制覆盖）：
  /// 1. 手动副本比上次同步新（设置页手动更新 → 真正落到内核目录）；
  /// 2. **App 升级后**（内置 geo 版本变化）→ 用新版覆盖内核目录旧文件，
  ///    否则老数据会一直被"幂等跳过"留在内核目录、长期不生效。
  /// 数据源优先级不变：手动副本 > 内置（升级不会用手动更新前的旧内置覆盖
  /// 用户手动更新的新版）。
  static Future<bool> materialize({String? preferDir}) async {
    try {
      final dirPath = preferDir ?? await _defaultDir();
      if (dirPath == null) return false;
      final dir = Directory(dirPath);
      if (!await dir.exists()) await dir.create(recursive: true);

      final manualAt = await manualUpdatedAt();
      var force = false;

      // 1) 手动副本更新 → 强制覆盖
      if (manualAt != null) {
        force = true;
        final stampFile = File('${dir.path}/.geo_synced');
        try {
          if (await stampFile.exists()) {
            final last = DateTime.tryParse(await stampFile.readAsString());
            if (last != null && !manualAt.isAfter(last)) force = false;
          }
        } catch (_) {
          force = true;
        }
      }
      // 2) App 升级(内置 geo 版本变化) → 强制覆盖(用手动副本或新版内置)
      if (!force) {
        final verFile = File('${dir.path}/.geo_app_ver');
        try {
          if (await verFile.exists()) {
            final syncedVer = (await verFile.readAsString()).trim();
            if (syncedVer == UpdateInfo.currentVersion) {
              force = false;
            } else {
              force = true;
            }
          } else {
            force = true; // 从未记录版本(旧安装首次连接) → 覆盖一次
          }
        } catch (_) {
          force = true;
        }
      }

      var ok = true;
      for (final file in files) {
        final target = File('${dir.path}/$file');
        if (!force && await target.exists() && await target.length() > 0) {
          continue;
        }
        final data = await readSource(file);
        if (data == null) {
          AppLog.error('GeoAssets 源缺失(内置/副本均不可用): $file');
          ok = false;
          continue;
        }
        try {
          await target.writeAsBytes(data, flush: true);
        } catch (e) {
          AppLog.error('GeoAssets 写入 $file 失败: $e');
          ok = false;
        }
      }
      // 记录同步状态
      try {
        await File('${dir.path}/.geo_app_ver')
            .writeAsString(UpdateInfo.currentVersion);
      } catch (_) {}
      if (manualAt != null) {
        try {
          await File('${dir.path}/.geo_synced')
              .writeAsString(manualAt.toIso8601String());
        } catch (_) {}
      }
      return ok;
    } catch (e) {
      AppLog.error('GeoAssets.materialize 失败: $e');
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
