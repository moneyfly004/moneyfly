import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../proxy/proxy_core.dart';

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
      {void Function(double progress)? onProgress}) async {
    if (!isDesktop) return 'not supported on this platform';
    if (ConnectionController.instance.status == ConnStatus.connected) {
      return 'kernel_running';
    }
    final bin = resolveBinaryPath();
    if (bin == null) return 'binary not found (run tool/fetch_mihomo.sh)';

    final tmp = Directory.systemTemp.createTempSync('mf_kernel_update');
    try {
      final asset = await _assetName(version);
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

  Future<String?> _assetName(String version) async {
    if (Platform.isMacOS) {
      final arch = await _macArch();
      return arch == 'arm64'
          ? 'mihomo-darwin-arm64-v$version.gz'
          : 'mihomo-darwin-amd64-v$version.gz';
    }
    if (Platform.isWindows) {
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
      final isArm = arch.toUpperCase().contains('ARM64');
      return isArm
          ? 'mihomo-windows-arm64-v$version.zip'
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
      // 定位 mihomo.exe（zip 内可能单文件或带目录）
      final found = Directory(dest)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('mihomo.exe'))
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

