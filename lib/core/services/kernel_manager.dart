import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../proxy/proxy_core.dart';
import 'settings_store.dart';

/// 内核变体：官方对 amd64(x64) 提供两种构建 ——
/// - [standard] 标准版：按新指令集(v3/AVX2)编译，新 CPU 性能好；
/// - [compatible] 兼容版：兼容老 CPU(无 AVX2 的老电脑)，与 macOS x64 同策略。
/// 老 CPU 跑标准版会启动即崩溃(0xC0000005)，故桌面 amd64 默认 compatible，
/// 用户可在「内核管理」里手动切换。
enum KernelVariant { standard, compatible }

extension KernelVariantX on KernelVariant {
  String get key => this == KernelVariant.compatible ? 'compatible' : 'standard';

  String get label => this == KernelVariant.compatible ? '兼容版' : '标准版';
}

/// 应用内内核管理（mihomo）：显示当前内置内核版本、检测官方最新版本、
/// 桌面端下载官方预编译二进制并热替换。
///
/// 内核来源：MetaCubeX/mihomo 官方 GitHub Release（与 CI 构建下载同源）。
/// Android 内核编译进 App（libmihomo.aar），无法运行期替换 —— 页面提示随 App 更新。
class KernelManager {
  KernelManager._();
  static final KernelManager instance = KernelManager._();

  /// 桌面端二进制查找路径（与 ProxyCoreCli.resolveBinary 一致）
  static String? resolveBinaryPath() {
    final override = Platform.environment['MONEYFLY_MIHOMO'];
    if (override != null && override.isNotEmpty && File(override).existsSync()) {
      return override;
    }
    final exe = Platform.resolvedExecutable;
    final candidates = <String>[
      if (Platform.isMacOS) '${Directory(exe).parent.path}/mihomo',
      '${Directory(exe).parent.path}/mihomo${Platform.isWindows ? '.exe' : ''}',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  static bool get isDesktop => !Platform.isAndroid && !Platform.isIOS;

  /// 归一化版本号（去掉 v 前缀）
  static String norm(String? v) {
    if (v == null) return '';
    var s = v.trim();
    if (s.startsWith('v')) s = s.substring(1);
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(s);
    if (m == null) return s;
    return '${m.group(1)}.${m.group(2)}.${m.group(3)}';
  }

  /// 比较版本，a > b 返回正数
  static int compare(String a, String b) {
    final pa = norm(a).split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = norm(b).split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x - y;
    }
    return 0;
  }

  KernelVariant _variant = KernelVariant.compatible;
  bool _variantLoaded = false;

  /// 当前偏好变体（默认 compatible，老 CPU 安全；设置可切换）
  Future<KernelVariant> currentVariant() async {
    if (!_variantLoaded) {
      try {
        final s = await SettingsStore.instance.load();
        final k = s['kernelVariant']?.toString();
        _variant = k == 'standard' ? KernelVariant.standard : KernelVariant.compatible;
      } catch (_) {}
      _variantLoaded = true;
    }
    return _variant;
  }

  Future<void> setVariant(KernelVariant v) async {
    _variant = v;
    try {
      final s = await SettingsStore.instance.load();
      s['kernelVariant'] = v.key;
      await SettingsStore.instance.save(s);
    } catch (_) {}
  }

  /// 该平台是否支持变体切换（桌面 x64/amd64；arm64 官方只有标准版）
  static Future<bool> get supportsVariant async {
    if (!isDesktop) return false;
    if (Platform.isMacOS) {
      final arch = await KernelManager.instance._macArch();
      return arch != 'arm64';
    }
    if (Platform.isWindows) {
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
      return !arch.toUpperCase().contains('ARM64');
    }
    return false;
  }

  /// 探测当前内置内核版本：  /// 探测当前内置内核版本：
  /// - 桌面：运行 `mihomo -v` 解析首行
  /// - Android：MethodChannel 读 libmihomo.Version()
  /// 失败返回 null（页面显示未知 + 提示）。
  Future<String?> detectCurrent() async {
    try {
      if (Platform.isAndroid) {
        const ch = MethodChannel('top.moneyfly/vpn_core');
        final v = await ch.invokeMethod<String>('kernelVersion');
        return norm(v);
      }
      final bin = resolveBinaryPath();
      if (bin == null) return null;
      final r = await Process.run(bin, ['-v'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      if (r.exitCode != 0) return null;
      final first = (r.stdout as String).split('\n').firstWhere(
          (l) => l.contains('Mihomo') || l.contains('mihomo'),
          orElse: () => '');
      final m = RegExp(r'v?(\d+\.\d+\.\d+)').firstMatch(first);
      return m?.group(1) ?? norm(first);
    } catch (e) {
      debugPrint('detectCurrent failed: $e');
      return null;
    }
  }

  /// 官方最新稳定版（GitHub API releases/latest → tag_name）
  Future<String?> fetchLatest() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ));
      final r = await dio.get('https://api.github.com/repos/MetaCubeX/mihomo/releases/latest');
      if (r.statusCode == 200 && r.data is Map) {
        final tag = (r.data as Map)['tag_name']?.toString();
        return tag == null ? null : norm(tag);
      }
      return null;
    } catch (e) {
      debugPrint('fetchLatest failed: $e');
      return null;
    }
  }

  /// 下载并替换内核（仅桌面端；要求内核未运行 —— Windows 进程占用 exe
  /// 无法覆盖，macOS 也存在句柄/签名问题）。返回空串=成功；非空=错误消息。
  ///
  /// [version] 目标版本（如 1.19.30）
  /// [onProgress] 下载进度回调（0~1）
  Future<String> updateTo(String version,
      {KernelVariant? variant, void Function(double progress)? onProgress}) async {
    if (!isDesktop) return 'not supported on this platform';
    if (ConnectionController.instance.status == ConnStatus.connected) {
      return 'kernel_running';
    }
    final bin = resolveBinaryPath();
    if (bin == null) return 'binary not found (run tool/fetch_mihomo.sh)';
    final v = variant ?? await currentVariant();

    final tmp = Directory.systemTemp.createTempSync('mf_kernel_update');
    try {
      final asset = await _assetName(version, v);
      if (asset == null) return 'unsupported platform/arch';
      final url =
          'https://github.com/MetaCubeX/mihomo/releases/download/v$version/$asset';
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 5),
      ));
      final archive = '${tmp.path}/$asset';
      await dio.download(url, archive, onReceiveProgress: (a, b) {
        if (b > 0) onProgress?.call(a / b);
      });

      // 解压出可执行文件
      final exePath = await _extract(archive, tmp.path);
      if (exePath == null) return 'extract failed: $asset';
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', exePath]);
      }
      // 新内核自检
      final check = await Process.run(exePath, ['-v'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      if (check.exitCode != 0) return 'downloaded kernel failed self-check';

      // 备份 → 替换 → 校验；失败回滚
      final oldFile = File(bin);
      final bak = File('$bin.old');
      try {
        if (bak.existsSync()) bak.deleteSync();
        if (oldFile.existsSync()) oldFile.renameSync(bak.path);
        File(exePath).copySync(bin);
        if (!Platform.isWindows) {
          await Process.run('chmod', ['+x', bin]);
        }
      } catch (e) {
        // 回滚
        try {
          if (!oldFile.existsSync() && bak.existsSync()) bak.renameSync(bin);
        } catch (_) {}
        return 'replace failed: $e';
      }
      // 替换后最终自检
      final verify = await Process.run(bin, ['-v'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      if (verify.exitCode != 0) {
        try {
          oldFile.deleteSync();
          bak.renameSync(bin);
        } catch (_) {}
        return 'updated kernel failed self-check, rolled back';
      }
      // 成功后清理备份
      try {
        if (bak.existsSync()) bak.deleteSync();
      } catch (_) {}
      return '';
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  Future<String?> _assetName(String version, KernelVariant variant) async {
    if (Platform.isMacOS) {
      final arch = await _macArch();
      if (arch == 'arm64') return 'mihomo-darwin-arm64-v$version.gz';
      // x64：标准版按新指令集(v3)编译，老 Intel/Rosetta 会启动即崩 → 默认兼容版
      return variant == KernelVariant.compatible
          ? 'mihomo-darwin-amd64-compatible-v$version.gz'
          : 'mihomo-darwin-amd64-v$version.gz';
    }
    if (Platform.isWindows) {
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
      if (arch.toUpperCase().contains('ARM64')) {
        return 'mihomo-windows-arm64-v$version.zip';
      }
      // amd64 默认兼容版(老 CPU 0xC0000005 崩溃防护)，用户可在内核管理切换标准版
      return variant == KernelVariant.compatible
          ? 'mihomo-windows-amd64-compatible-v$version.zip'
          : 'mihomo-windows-amd64-v$version.zip';
    }
    return null;
  }

  Future<String> _macArch() async {
    try {
      final r = await Process.run('uname', ['-m']);
      final out = (r.stdout as String).trim();
      return out.contains('arm') || out.contains('aarch64') ? 'arm64' : 'amd64';
    } catch (_) {
      return 'arm64';
    }
  }

  /// 解压并返回可执行文件路径：
  /// - macOS .gz → 单文件，gunzip 产物
  /// - Windows .zip → Expand-Archive 后定位 mihomo.exe
  Future<String?> _extract(String archive, String dir) async {
    if (Platform.isMacOS) {
      final out = archive.replaceFirst('.gz', '');
      final r = await Process.run('gunzip', ['-f', '-k', archive]);
      if (r.exitCode != 0) return null;
      return File(out).existsSync() ? out : null;
    }
    if (Platform.isWindows) {
      final dest = '$dir/unzipped';
      Directory(dest).createSync(recursive: true);
      final winZip = archive.replaceAll('/', r'\');
      final winDest = dest.replaceAll('/', r'\');
      final r = await Process.run('powershell', [
        '-NoProfile', '-Command',
        'Expand-Archive -Path "$winZip" -DestinationPath "$winDest" -Force',
      ]);
      if (r.exitCode != 0) return null;
      // 定位内核 exe（官方 zip 内文件名带平台前缀：mihomo-windows-amd64.exe，
      // 按 .exe 扩展名取唯一文件）
      final found = Directory(dest)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) =>
              f.path.toLowerCase().endsWith('.exe') &&
              !f.path.toLowerCase().endsWith('mihomo.exe.old'))
          .toList();
      if (found.isEmpty) return null;
      final exe = found.first.path;
      // 拷到 dir 根，统一返回路径
      final target = '$dir/mihomo.exe';
      File(exe).copySync(target);
      return target;
    }
    return null;
  }
}

