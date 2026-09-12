import 'dart:io';

import 'package:dio/dio.dart';

import '../api/api_client.dart';
import '../proxy/geo_assets.dart';

/// 分流数据(Geo)手动更新服务：在「设置 → 更新分流数据」中由用户主动触发，
/// 从官方源(MetaCubeX/meta-rules-dat latest)下载最新 geosite.dat/country.mmdb
/// 到本地可写副本目录，随后 [GeoAssets] 落盘内核目录时优先使用副本。
///
/// 设计要点（对应「构建自带 + 设置手动更新 + 启动零联网」）：
/// - **出厂自带**：安装包内置构建当天最新的 geo 数据(assets/rules)，离线可用；
/// - **启动/连接零联网**：运行链路只读内置或本地副本，从不联网；本服务只在
///   用户显式点击「检查并更新」时才发起下载，失败不影响软件与内核启动；
/// - 下载文件先写临时文件再原子改名，避免半包损坏覆盖可用副本；
/// - 更新后的副本在 supportDir/geo/ 持久保留，版本升级(老安装)不清除。
class GeoUpdateService {
  GeoUpdateService._();
  static final GeoUpdateService instance = GeoUpdateService._();

  /// 更新来源：MetaCubeX/meta-rules-dat 最新 release（与 CI 构建下载同源）
  static const _repo = 'MetaCubeX/meta-rules-dat';
  static const _baseUrl =
      'https://github.com/$_repo/releases/latest/download';

  /// 每个文件最小合理体积（字节）：mmdb ~7MB / dat ~4MB，小于 1MB 视为坏包
  static const _minSize = 1 << 20;

  /// 下载客户端：裸 GitHub（不经 ApiClient，避免注入登录 token 导致 401）
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 20),
    followRedirects: true,
    headers: {'User-Agent': ApiClient.userAgent},
  ));

  static const files = ['geosite.dat', 'country.mmdb'];

  /// 是否已存在手动更新副本
  static Future<bool> hasManualCopy(String file) async {
    final dir = await GeoAssets.updatedDir();
    if (dir == null) return false;
    try {
      final f = File('$dir/$file');
      return await f.exists() && await f.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 检查并更新：逐个下载最新 geo 文件到副本目录。
  /// 返回 (成功文件数, 失败信息列表)；空错误列表 = 全部成功。
  Future<({int ok, List<String> errors})> update(
      {void Function(int done, int total)? onFile}) async {
    final dir = await GeoAssets.updatedDir();
    if (dir == null) {
      return (ok: 0, errors: ['无法获取本地存储目录']);
    }
    try {
      await Directory(dir).create(recursive: true);
    } catch (_) {}

    var ok = 0;
    final errors = <String>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      try {
        await _downloadOne(dir, file);
        ok++;
      } catch (e) {
        errors.add('$file: $e');
      }
      onFile?.call(i + 1, files.length);
    }
    // 只要有文件更新成功就记录时间（旧实现要求 ok == files.length）。
    // GeoAssets 依据这个时间戳决定是否把「手动副本」强制覆盖到内核目录；
    // 若部分成功（如 country.mmdb 失败）就不记，则已下载成功的新
    // geosite.dat 永远不会同步到内核目录 —— 用户看到「更新失败」，磁盘上
    // 却躺着一个永不生效的新副本。
    if (ok > 0) {
      await GeoAssets.markUpdatedAt(DateTime.now());
    }
    return (ok: ok, errors: errors);
  }

  Future<void> _downloadOne(String dir, String file) async {
    final tmp = File('$dir/.$file.part');
    final target = File('$dir/$file');
    final r = await _dio.download(
      '$_baseUrl/$file',
      tmp.path,
      deleteOnError: true,
    );
    if (r.statusCode != 200) {
      throw HttpException('HTTP ${r.statusCode}');
    }
    final size = await tmp.length();
    if (size < _minSize) {
      try { await tmp.delete(); } catch (_) {}
      throw Exception('文件过小(${(size / 1024).round()}KB)，疑似错误响应');
    }
    // 原子替换：先删旧再改名（跨平台安全）
    if (await target.exists()) {
      try { await target.delete(); } catch (_) {}
    }
    await tmp.rename(target.path);
  }
}
