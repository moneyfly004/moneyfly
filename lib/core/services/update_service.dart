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

  /// 是否有新版本（全局红点：底部「我的」tab、设置「版本更新」行共用）。
  /// 启动后台检查与设置页手动检查都会刷新它。
  static final ValueNotifier<bool> hasUpdate = ValueNotifier(false);

  static const String githubRepo = 'moneyfly004/moneyfly';

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
      hasUpdate.value = _cacheInfo!.isNewer;
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

      // 按平台匹配资产（同时取回被选中资产的体积，保证展示与实际下载一致）
      final assets = (data['assets'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final picked = await _pickAsset(assets);
      if (picked == null) return null;

      _cacheInfo = UpdateInfo(
        latestVersion: version,
        downloadUrl: picked.url,
        sizeText: _sizeText(picked.size),
      );
      _cacheAt = DateTime.now();
      hasUpdate.value = _cacheInfo!.isNewer;
      return _cacheInfo;
    } catch (_) {
      return null;
    }
  }

  /// 选择本平台安装包资产(macOS 按真实架构选 arm64/x64 dmg,避免 Intel 拿到 arm64)
  static Future<({String url, int size})?> _pickAsset(List<Map> assets) async {
    final entries = assets
        .map((a) => (
              name: a['name']?.toString() ?? '',
              url: a['browser_download_url']?.toString() ?? '',
              size: (a['size'] as num?)?.toInt() ?? 0,
            ))
        .toList();
    if (kIsWeb) return null;
    // 本平台的**可接受前缀集合**：兜底也只在集合内挑，避免把 Android APK
    // 或另一架构的包发给当前平台（旧兜底是「名字含 MoneyFly- 就用」）。
    final List<String> prefixes;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        // 主流机型 arm64-v8a(个别老 32 位机型请手动装对应 APK)
        prefixes = const ['MoneyFly-android-arm64-v8a-'];
        break;
      case TargetPlatform.iOS:
        return null;
      case TargetPlatform.macOS:
        prefixes = await _isMacIntel()
            ? const ['MoneyFly-macos-x64-']
            : const ['MoneyFly-macos-arm64-'];
        break;
      case TargetPlatform.windows:
        prefixes = const ['MoneyFly-setup-'];
        break;
      default:
        return null; // 未知平台：宁可不提示更新，也不给错包
    }
    for (final p in prefixes) {
      for (final e in entries) {
        if (e.name.startsWith(p) && e.url.isNotEmpty) {
          return (url: e.url, size: e.size);
        }
      }
    }
    // 宽松兜底仍限定在同平台前缀内（例如版本号命名变化导致前缀不完全匹配）
    final platTag = prefixes.first.replaceAll(RegExp(r'(x64|arm64|arm64-v8a|ia32)-$'), '');
    for (final e in entries) {
      if (e.url.isNotEmpty && e.name.startsWith(platTag)) {
        return (url: e.url, size: e.size);
      }
    }
    return null;
  }

  static Future<bool> _isMacIntel() async {
    try {
      final r = await Process.run('uname', ['-m']);
      final out = (r.stdout as String).trim();
      return out.contains('x86_64');
    } catch (_) {
      return false;
    }
  }

  static String? _sizeText(int size) {
    if (size <= 0) return null;
    if (size >= 1 << 30) return '${(size / (1 << 30)).toStringAsFixed(1)} GB';
    if (size >= 1 << 20) return '${(size / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }
}
