import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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

  static String get _exeName =>
      Platform.isWindows ? 'mihomo.exe' : 'mihomo';

  /// 用户内核副本目录（应用支持目录/kernel，各平台均可写）。
  /// 切换/更新的内核放这里，**绝不动安装目录** —— 装到 Program Files 等
  /// 只读目录也能正常切换/更新内核。
  static Future<Directory?> userKernelDir() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/kernel');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// 用户「当前生效」内核副本路径（不存在返回 null）
  static Future<String?> userActivePath() async {
    try {
      final dir = await userKernelDir();
      if (dir == null) return null;
      final f = File('${dir.path}/$_exeName');
      return await f.exists() ? f.path : null;
    } catch (_) {
      return null;
    }
  }

  /// 是否已存在用户切换/更新的内核（有则可「恢复内置」）
  static Future<bool> hasUserKernel() async =>
      (await userActivePath()) != null;

  /// 生效内核查找优先级：测试注入(MONEYFLY_MIHOMO) → 用户副本 → 安装内置
  static Future<String?> resolveKernelPath() async {
    final override = Platform.environment['MONEYFLY_MIHOMO'];
    if (override != null && override.isNotEmpty && File(override).existsSync()) {
      return override;
    }
    final user = await userActivePath();
    if (user != null) return user;
    final exe = Platform.resolvedExecutable;
    final candidates = <String>[
      if (Platform.isMacOS) '${Directory(exe).parent.path}/$_exeName',
      '${Directory(exe).parent.path}/$_exeName',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 删除用户副本 → 回到安装包内置内核（无需下载）。返回是否成功清除。
  static Future<bool> restoreBuiltin() async {
    try {
      final dir = await userKernelDir();
      if (dir == null) return false;
      for (final name in [_exeName, '.$_exeName.bak']) {
        try {
          final f = File('${dir.path}/$name');
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 平台内置内核的变体（安装包随 CI 打包的构建）
  static Future<KernelVariant> builtinVariantForPlatform() async {
    if (Platform.isMacOS && (await KernelManager.instance._macArch()) != 'arm64') {
      return KernelVariant.compatible;
    }
    if (Platform.isWindows) {
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
      if (!arch.toUpperCase().contains('ARM64')) return KernelVariant.compatible;
    }
    return KernelVariant.standard;
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

  /// 探测当前内置内核版本：
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
      final bin = await resolveKernelPath();
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

  /// 切换/更新内核（仅桌面端；要求内核未运行）。返回空串=成功；非空=错误消息。
  ///
  /// 写入位置为「用户副本目录」（userKernelDir，可写），**绝不修改安装目录**，
  /// 装到 Program Files 等只读目录也能切换/更新。
  /// 下载缓存：`cache/<variant>_<version>` —— 本地已有该 (变体,版本) 内核时
  /// 直接激活、不再下载；来回切换不重复下载。「恢复内置」= 删除用户副本。
  ///
  /// [version] 目标版本（如 1.19.30）
  /// [variant] 目标变体（默认当前偏好）
  /// [onProgress] 下载进度回调（0~1）
  Future<String> updateTo(String version,
      {KernelVariant? variant, void Function(double progress)? onProgress}) async {
    if (!isDesktop) return 'not supported on this platform';
    if (ConnectionController.instance.status == ConnStatus.connected) {
      return 'kernel_running';
    }
    final v = variant ?? await currentVariant();
    final asset = await _assetName(version, v);
    if (asset == null) return 'unsupported platform/arch';
    final dir = await userKernelDir();
    if (dir == null) return 'no writable kernel dir';
    final cacheFile = File('${dir.path}/cache/${v.key}_$version$_exeName');

    // 1) 缓存命中 → 直接本地激活（不再下载，秒切）
    if (await cacheFile.exists() && await cacheFile.length() > 0) {
      return await _activate(dir, cacheFile);
    }

    // 2) 下载官方预编译 → 解压 → 自检 → 写入缓存 → 激活
    final tmp = Directory.systemTemp.createTempSync('mf_kernel_update');
    try {
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

      final exePath = await _extract(archive, tmp.path);
      if (exePath == null) return 'extract failed: $asset';
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', exePath]);
      }
      // 新内核自检
      final check = await Process.run(exePath, ['-v'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      if (check.exitCode != 0) return 'downloaded kernel failed self-check';

      // 写缓存（保留，切换回该 (变体,版本) 不再下载）
      try {
        await Directory('${dir.path}/cache').create(recursive: true);
        File(exePath).copySync(cacheFile.path);
        if (!Platform.isWindows) {
          await Process.run('chmod', ['+x', cacheFile.path]);
        }
      } catch (e) {
        return 'cache write failed: $e';
      }
      return await _activate(dir, cacheFile);
    } finally {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 把缓存内核激活为「当前生效」（userKernelDir/mihomo[.exe]），带备份回滚与自检
  Future<String> _activate(Directory dir, File cacheFile) async {
    final active = File('${dir.path}/$_exeName');
    final bak = File('${dir.path}/.$_exeName.bak');
    try {
      if (await active.exists()) {
        if (await bak.exists()) await bak.delete();
        await active.rename(bak.path);
      }
      await cacheFile.copy(active.path);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', active.path]);
      }
    } catch (e) {
      // 回滚
      try {
        if (!await active.exists() && await bak.exists()) {
          await bak.rename(active.path);
        }
      } catch (_) {}
      return 'activate failed: $e';
    }
    // 自检
    final verify = await Process.run(active.path, ['-v'],
        environment: {'PATH': Platform.environment['PATH'] ?? ''});
    if (verify.exitCode != 0) {
      try {
        if (await active.exists()) await active.delete();
        if (await bak.exists()) await bak.rename(active.path);
      } catch (_) {}
      return 'kernel failed self-check, rolled back';
    }
    try {
      if (await bak.exists()) await bak.delete();
    } catch (_) {}
    return '';
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

