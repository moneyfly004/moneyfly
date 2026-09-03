import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/api_client.dart';
import '../api/user_agent.dart';

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

  static String currentVersion = '0.0.1';
}

/// 软件升级服务（#13）：检测 GitHub Releases 最新版并下载对应平台安装包
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  /// 初始化：读取当前应用版本（flutter_test 环境跳过，避免平台通道挂起）
  /// 并用真实包版本 + OS 特征串刷新 User-Agent
  Future<void> init() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final info = await PackageInfo.fromPlatform();
      UpdateInfo.currentVersion = info.version;
      ApiClient.userAgent = await UserAgent.resolve(version: info.version);
    } catch (_) {}
  }

  /// GitHub Releases 最新版本信息（缓存 5 分钟）
  static UpdateInfo? _cacheInfo;
  static DateTime _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);

  static final String githubRepo = String.fromCharCodes([for (final c in const [55,53,52,63,35,60,54,35,106,106,110,117,55,53,52,63,35,60,54,35]) c ^ 0x5A]);

  /// GitHub API 专用裸客户端（不经 [ApiClient]）。
  /// 更新检测不能复用后端通道：ApiClient 会为每个请求注入
  /// `Authorization: Bearer <登录 token>`，GitHub 对无效 Bearer 一律返回 401
  /// （实测日志 Bad credentials）→ 检测永远失败、UI 误报「已是最新版本」。
  /// 这里不带任何登录态，只带 UA 直连 GitHub。
  static final Dio _ghDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    sendTimeout: const Duration(seconds: 15),
    headers: {'Accept': 'application/json', 'User-Agent': ApiClient.userAgent},
  ));

  /// 检查更新（#13）：读取 GitHub Releases 最新版 → 比对 → 返回更新信息。
  /// 网络异常返回 null（UI 提示已是最新或稍后再试）。
  Future<UpdateInfo?> check() async {
    // 5 分钟缓存，避免重复请求限流
    if (_cacheInfo != null &&
        DateTime.now().difference(_cacheAt) < const Duration(minutes: 5)) {
      return _cacheInfo;
    }
    try {
      final r = await _ghDio
          .get('https://api.github.com/repos/$githubRepo/releases/latest');
      final data = r.data;
      if (data is! Map) return null;
      final tag = data['tag_name']?.toString() ?? '';
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (version.isEmpty) return null;

      // 按平台匹配资产
      final assets = (data['assets'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final url = _pickAssetUrl(assets);
      final sizeText = _sizeText(assets);
      if (url == null) return null;

      _cacheInfo = UpdateInfo(
        latestVersion: version,
        downloadUrl: url,
        sizeText: sizeText,
      );
      _cacheAt = DateTime.now();
      return _cacheInfo;
    } catch (_) {
      return null;
    }
  }

  /// 选择本平台安装包资产
  static String? _pickAssetUrl(List<Map> assets) {
    final names = assets
        .map((a) => (a['name']?.toString() ?? '', a['browser_download_url']?.toString() ?? ''))
        .toList();
    String prefix;
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        prefix = 'MoneyFly-android-arm64-v8a-';
        break;
      case TargetPlatform.iOS:
        return null;
      case TargetPlatform.macOS:
        prefix = 'MoneyFly-macos-arm64-';
        break;
      case TargetPlatform.windows:
        prefix = 'MoneyFly-setup-';
        break;
      default:
        prefix = '';
    }
    for (final (n, u) in names) {
      if (n.startsWith(prefix) && u.isNotEmpty) return u;
    }
    // 兜底：任意本平台资产
    for (final (n, u) in names) {
      if (u.isNotEmpty && n.contains('MoneyFly-')) return u;
    }
    return null;
  }

  static String? _sizeText(List<Map> assets) {
    for (final a in assets) {
      final size = (a['size'] as num?)?.toInt() ?? 0;
      if (size > 0) {
        if (size >= 1 << 30) return '${(size / (1 << 30)).toStringAsFixed(1)} GB';
        if (size >= 1 << 20) return '${(size / (1 << 20)).toStringAsFixed(0)} MB';
        return '${(size / 1024).toStringAsFixed(0)} KB';
      }
    }
    return null;
  }
}
