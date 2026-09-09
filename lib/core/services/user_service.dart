import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';
import '../utils/serial_executor.dart';
import 'local_paths.dart';

/// 用户服务：我的信息 / 仪表盘
class UserService {
  UserService._();
  static final UserService instance = UserService._();

  static const _cacheFileName = 'dashboard_cache.json';

  /// 磁盘缓存读写串行队列：登出删除与新登录写回按顺序执行，避免竞态
  static final SerialExecutor _cacheIoQueue = SerialExecutor();

  /// 内存缓存（会话内）：进入「我的」页只拉一次，切 tab 不重复刷新
  DashboardInfo? _dashboardCache;

  DashboardInfo? get cachedDashboard => _dashboardCache;

  /// 拉取仪表盘（[force] 强制刷新；默认按 内存→磁盘→网络 逐级命中）
  Future<DashboardInfo> dashboard({bool force = false}) async {
    if (!force && _dashboardCache != null) return _dashboardCache!;
    if (!force) {
      final cached = await loadCachedDashboard();
      if (cached != null) {
        _dashboardCache = cached;
        return cached;
      }
    }
    final data = await ApiClient.instance.get(Endpoints.dashboardInfo);
    _dashboardCache =
        DashboardInfo.fromJson(Map<String, dynamic>.from(data as Map));
    unawaited(_enqueueCacheIo(() => _persist(_dashboardCache!)));
    return _dashboardCache!;
  }

  /// 读取磁盘缓存的仪表盘（冷启动进入「我的」页先展示，再后台刷新）
  Future<DashboardInfo?> loadCachedDashboard() async {
    try {
      final f = await _cacheFile();
      if (f == null || !f.existsSync()) return null;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map) {
        return DashboardInfo.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return null;
  }

  /// 把已有仪表盘注入内存缓存（不落盘；「我的」页冷启动展示磁盘缓存用）
  void adoptCachedDashboard(DashboardInfo info) => _dashboardCache = info;

  /// 登出 / 换号 / 套餐变更后清缓存，下次进入重新加载
  /// （防止上一账号的仪表盘数据残留到下一账号）
  void invalidateCache() {
    _dashboardCache = null;
    unawaited(_enqueueCacheIo(_deleteCacheFile));
  }

  Future<File?> _cacheFile() async {
    final dir = await LocalPaths.supportDir();
    if (dir == null) return null;
    return File('${dir.path}/$_cacheFileName');
  }

  Future<void> _persist(DashboardInfo info) async {
    try {
      final f = await _cacheFile();
      if (f == null) return;
      await f.writeAsString(jsonEncode(info.toJson()), flush: true);
    } catch (_) {}
  }

  Future<void> _deleteCacheFile() async {
    try {
      final f = await _cacheFile();
      if (f != null && f.existsSync()) await f.delete();
    } catch (_) {}
  }

  static Future<void> _enqueueCacheIo(Future<void> Function() job) =>
      _cacheIoQueue.run(job);

  Future<UserInfo> me() async {
    final data = await ApiClient.instance.get(Endpoints.me);
    return UserInfo.fromJson(Map<String, dynamic>.from(data as Map));
  }
}
