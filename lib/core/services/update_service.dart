import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/api_client.dart';
import '../api/endpoints.dart';

/// 软件升级信息
class UpdateInfo {
  final String latestVersion;
  final String? downloadUrl;
  final String? sizeText;
  final bool forced;

  UpdateInfo({required this.latestVersion, this.downloadUrl, this.sizeText, this.forced = false});

  bool get isNewer {
    final cur = _parse(currentVersion);
    final latest = _parse(latestVersion);
    if (cur == null || latest == null) return latestVersion != currentVersion;
    return latest.compareTo(cur) > 0;
  }

  static String? _parse(String v) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(v);
    if (m == null) return null;
    return '${int.parse(m.group(1)!).toString().padLeft(3, '0')}'
        '${int.parse(m.group(2)!).toString().padLeft(3, '0')}'
        '${int.parse(m.group(3)!).toString().padLeft(3, '0')}';
  }

  static String currentVersion = '1.0.0';
}

/// 软件升级服务：读 /software/versions，扫描 MoneyFly 平台条目比对版本
/// 后端发布安装包后，在软件库添加 key 形如 moneyfly_android_url / moneyfly_macos_url 即可生效
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static String get _platformKey {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      _ => 'other',
    };
  }

  /// 初始化：读取当前应用版本
  Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      UpdateInfo.currentVersion = info.version;
    } catch (_) {}
  }

  /// 检查更新；无更新源配置时返回 null
  Future<UpdateInfo?> check() async {
    try {
      final data = await ApiClient.instance.get(Endpoints.softwareVersions);
      if (data is! Map || data['list'] is! List) return null;
      final list = data['list'] as List;
      Map<String, dynamic>? match;
      for (final e in list) {
        if (e is! Map) continue;
        final key = e['key']?.toString() ?? '';
        if (key.contains('moneyfly') && key.contains(_platformKey)) {
          match = Map<String, dynamic>.from(e);
          break;
        }
      }
      if (match == null) return null;
      final urlKey = 'moneyfly_${_platformKey}_url';
      return UpdateInfo(
        latestVersion: match['version']?.toString() ?? '0.0.0',
        downloadUrl: match['download_url']?.toString() ?? match[urlKey]?.toString(),
        sizeText: match['size_text']?.toString(),
        forced: match['forced'] == true || match['force_update'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
