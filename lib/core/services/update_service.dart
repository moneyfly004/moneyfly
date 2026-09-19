import 'dart:io';

import 'package:app_installer/app_installer.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_client.dart';
import '../api/user_agent.dart';

/// 软件升级信息
class UpdateInfo {
  final String latestVersion;
  final String? downloadUrl;
  final String? sizeText;
  final bool forced;

  /// 与本机平台/架构匹配的那个安装包的文件名（下载落盘用它命名）
  final String? assetName;

  /// 该安装包在 `SHA256SUMS*.txt` 里的校验值（拿不到则为空）
  final String sha256;

  UpdateInfo({
    required this.latestVersion,
    this.downloadUrl,
    this.sizeText,
    this.forced = false,
    this.assetName,
    this.sha256 = '',
  });

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

/// 软件升级服务：检测 GitHub Releases 最新版 → **后台下载匹配本机的安装包**
/// → 点击「立即更新」直接调起安装器（对齐 mclash 的更新体验）。
///
/// 为什么不能只丢一个下载链接：
/// - 用户得自己找对平台/架构的包（下错架构会启动即崩）；
/// - 浏览器下载完还要手动找文件双击；
/// - 下载中没有任何进度反馈。
/// 现在这些都由客户端完成：挑包 → 预下载（带进度、校验 sha256）→ 调起安装器。
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

  /// 最近一次检查到的更新信息（弹窗用它拿版本号/体积/下载地址）
  static UpdateInfo? get lastInfo => _cacheInfo;

  /// 是否有新版本（全局红点：底部「我的」tab、设置「版本更新」行共用）。
  /// 启动后台检查与设置页手动检查都会刷新它。
  static final ValueNotifier<bool> hasUpdate = ValueNotifier(false);

  /// 后台下载进度（0~1；null = 未在下载）
  static final ValueNotifier<double?> downloadProgress = ValueNotifier(null);

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

  /// 测试缝：替换整段「查最新版本」逻辑（单测不打网络）
  @visibleForTesting
  static Future<UpdateInfo?> Function()? debugCheckOverride;

  /// 测试缝：替换真实下载（单测不写盘、不打网络）
  @visibleForTesting
  static Future<void> Function(String url, String savePath)? debugDownloadOverride;

  /// 测试缝：替换「调起安装器」
  @visibleForTesting
  static Future<bool> Function(String path)? debugLaunchInstallerOverride;

  /// 测试缝：替换缓存目录
  @visibleForTesting
  static Future<Directory?> Function()? debugCacheDir;

  /// 检查更新：读取 GitHub Releases 最新版 → 比对 → 返回更新信息。
  /// 网络异常返回 null（UI 提示已是最新或稍后再试）。
  Future<UpdateInfo?> check() async {
    final override = debugCheckOverride;
    if (override != null) {
      final info = await override();
      _cacheInfo = info;
      hasUpdate.value = info?.isNewer ?? false;
      return info;
    }
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
        assetName: picked.name,
        // 顺带取 sha256：下载完校验完整性（拿不到就跳过校验，不阻塞更新）
        sha256: await _fetchSha256(assets, picked.name),
      );
      _cacheAt = DateTime.now();
      hasUpdate.value = _cacheInfo!.isNewer;
      return _cacheInfo;
    } catch (_) {
      return null;
    }
  }

  /// 选择本平台安装包资产(macOS 按真实架构选 arm64/x64 dmg,避免 Intel 拿到 arm64)
  static Future<({String url, int size, String name})?> _pickAsset(
      List<Map> assets) async {
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
        // iOS 走侧载分发（IPA 挂 GitHub Releases）：TrollStore / 自签安装。
        // 只提示新版本 + 给出 IPA 下载地址，不在 App 内自更新（系统不允许）。
        prefixes = const ['MoneyFly-ios-'];
        break;
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
          return (url: e.url, size: e.size, name: e.name);
        }
      }
    }
    // 宽松兜底仍限定在同平台前缀内（例如版本号命名变化导致前缀不完全匹配）
    final platTag = prefixes.first.replaceAll(RegExp(r'(x64|arm64|arm64-v8a|ia32)-$'), '');
    for (final e in entries) {
      if (e.url.isNotEmpty && e.name.startsWith(platTag)) {
        return (url: e.url, size: e.size, name: e.name);
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

  /// 从 `SHA256SUMS*.txt` 里取本平台安装包的校验值（缺失返回空串）。
  static Future<String> _fetchSha256(List<Map> assets, String assetName) async {
    final sumsName = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'SHA256SUMS.txt',
      TargetPlatform.windows => 'SHA256SUMS.txt',
      TargetPlatform.iOS => 'SHA256SUMS-ios.txt',
      TargetPlatform.macOS => assetName.contains('-macos-arm64-')
          ? 'SHA256SUMS-macos-arm64.txt'
          : assetName.contains('-macos-universal-')
              ? 'SHA256SUMS-macos-universal.txt'
              : 'SHA256SUMS-macos-x64.txt',
      _ => '',
    };
    if (sumsName.isEmpty) return '';
    final sums = assets
        .where((a) => a['name'] == sumsName)
        .map((a) => a['browser_download_url']?.toString() ?? '')
        .firstWhere((u) => u.isNotEmpty, orElse: () => '');
    if (sums.isEmpty) return '';
    try {
      final text = (await _ghDio.get<String>(sums,
              options: Options(responseType: ResponseType.plain)))
          .data ??
          '';
      for (final line in text.split('\n')) {
        if (!line.contains(assetName)) continue;
        final hash = line.trim().split(RegExp(r'\s+')).first.toLowerCase();
        if (hash.length == 64) return hash;
      }
    } catch (_) {}
    return '';
  }

  // ==================== 下载 / 安装（对齐 mclash 的更新体验）====================

  /// 测试缝：强制「本平台支持应用内安装」。
  ///
  /// 为什么必须有：CI 的 Android job 在 **ubuntu** 上跑测试，而真实判定依赖
  /// 宿主平台 → 那里恒为 false，凡是断言「点了立即更新就会调起安装器」的用例
  /// 都会红（实测 v2.2.9 就是这么挂的）。把判定做成可注入，用例就能在任意宿主
  /// 上覆盖两条分支。
  @visibleForTesting
  static bool? debugCanInstallInApp;

  /// 本平台是否支持**应用内直接调起安装**
  /// - iOS 不允许自更新（侧载 IPA），只给下载地址
  static bool get canInstallInApp =>
      debugCanInstallInApp ??
      (!kIsWeb && (Platform.isAndroid || Platform.isWindows || Platform.isMacOS));

  Future<Directory?> _updateDir() async {
    final base = debugCacheDir != null
        ? await debugCacheDir!()
        : await getApplicationCacheDirectory();
    if (base == null) return null;
    final dir = Directory('${base.path}/update');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 已下载安装包的路径（存在且非空才有值）
  Future<String?> downloadedInstaller([UpdateInfo? info]) async {
    final i = info ?? _cacheInfo;
    final name = i?.assetName;
    if (name == null || name.isEmpty) return null;
    final dir = await _updateDir();
    if (dir == null) return null;
    final f = File('${dir.path}/$name');
    if (!f.existsSync() || f.lengthSync() == 0) return null;
    return f.path;
  }

  /// 后台/前台下载本机匹配的安装包（幂等：已下好直接返回路径）。
  ///
  /// [onProgress] 0~1；有 sha256 就校验，校验失败会删掉文件并返回 null
  /// （宁可让用户重新下，也不装一个被篡改/下坏的包）。
  Future<String?> downloadInstaller({
    UpdateInfo? info,
    void Function(double progress)? onProgress,
  }) async {
    final i = info ?? _cacheInfo;
    final url = i?.downloadUrl;
    final name = i?.assetName;
    if (url == null || url.isEmpty || name == null || name.isEmpty) return null;
    final dir = await _updateDir();
    if (dir == null) return null;
    final path = '${dir.path}/$name';
    final dest = File(path);
    if (dest.existsSync() && dest.lengthSync() > 0) {
      downloadProgress.value = 1;
      return path;
    }
    // 并发去重：后台预下载与用户点「立即更新」会同时触发同一份下载，
    // 两个写入方写同一个文件会把包写坏 → 后来的等前一个的结果。
    final pending = _inFlight[name];
    if (pending != null) return pending;
    final task = _downloadTo(url, name, path, dest, onProgress, i!.sha256);
    _inFlight[name] = task;
    try {
      return await task;
    } finally {
      // ignore: unawaited_futures — Map.remove 返回被删的 Future，这里只是清理表项
      _inFlight.remove(name);
    }
  }

  static final Map<String, Future<String?>> _inFlight = {};

  static Future<String?> _downloadTo(String url, String name, String path,
      File dest, void Function(double progress)? onProgress,
      String expectSha) async {
    final override = debugDownloadOverride;
    downloadProgress.value = 0;
    try {
      if (override != null) {
        await override(url, path);
      } else {
        await _ghDio.download(url, path, onReceiveProgress: (received, total) {
          if (total <= 0) return;
          final p = received / total;
          downloadProgress.value = p;
          onProgress?.call(p);
        });
      }
      // 校验值取自**本次下载用的 info**：早先写成读全局缓存，导致「显式传 info
      // 的调用」压根不校验（单测直接抓到：给了错哈希仍然返回成功）。
      if (expectSha.isNotEmpty) {
        final actual = await _sha256Of(dest);
        if (actual != expectSha) {
          try {
            dest.deleteSync();
          } catch (_) {}
          downloadProgress.value = null;
          return null;
        }
      }
      downloadProgress.value = 1;
      return path;
    } catch (_) {
      try {
        if (dest.existsSync()) dest.deleteSync();
      } catch (_) {}
      downloadProgress.value = null;
      return null;
    }
  }

  static Future<String> _sha256Of(File f) async {
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }

  /// 调起系统安装器（Windows/macOS 打开安装包；Android 交给系统包安装器）。
  /// **不退出进程** —— 退出由上层在断连后决定，避免装到一半内核还在跑。
  Future<bool> launchInstaller(String path) async {
    final override = debugLaunchInstallerOverride;
    if (override != null) return override(path);
    if (Platform.isAndroid) {
      // 动态导入避免桌面端引入无关插件代码
      // ignore: avoid_dynamic_calls
      return _installApk(path);
    }
    if (Platform.isWindows || Platform.isMacOS) {
      if (Platform.isMacOS) await clearQuarantine(path);
      try {
        return await launchUrl(Uri.file(path),
            mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  Future<bool> _installApk(String path) async {
    try {
      await _apkInstaller(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 测试缝：替换 APK 安装器（单测不真调系统安装器）
  @visibleForTesting
  static Future<void> Function(String path)? apkInstaller;

  static Future<void> _apkInstaller(String path) {
    final fn = apkInstaller;
    if (fn != null) return fn(path);
    // 只在 Android 分支被调用（见 [launchInstaller]），桌面/iOS 不会走到这里
    return AppInstaller.installApk(path);
  }

  /// macOS：清掉下载文件的隔离属性，否则 Gatekeeper 会拦下安装包
  /// （浏览器下载才有该属性，Dio 下载一般没有；这里兜底，幂等且失败不致命）
  @visibleForTesting
  static Future<void> clearQuarantine(String path) async {
    if (!Platform.isMacOS) return;
    try {
      await Process.run('xattr', ['-c', path]);
    } catch (_) {}
  }

  /// 测试缝：重置缓存与进度
  @visibleForTesting
  static void resetForTest() {
    _cacheInfo = null;
    _cacheAt = DateTime.fromMillisecondsSinceEpoch(0);
    hasUpdate.value = false;
    downloadProgress.value = null;
    debugCheckOverride = null;
    debugDownloadOverride = null;
    debugLaunchInstallerOverride = null;
    debugCacheDir = null;
    apkInstaller = null;
    debugCanInstallInApp = null;
  }
}
