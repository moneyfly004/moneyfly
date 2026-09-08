import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../models/models.dart';
import 'settings_store.dart';

/// 真实出口国家检测：连接成功后，通过隧道（本地混合代理端口，设置页可改，
/// 默认 2080）请求 IP 地理定位接口，返回**实际出口 IP 所在国家**——
/// 不是按节点名猜测。
class GeoLookupService {
  GeoLookupService._();
  static final GeoLookupService instance = GeoLookupService._();

  /// 本地混合代理端口默认值（与设置默认一致；实际值每次查询时读设置，
  /// 支持用户在设置页自定义端口）
  static const defaultPort = 2080;

  /// 清理缓存（切换账号/登出时调用，避免旧账号出口残留展示）
  void clearCache() {
    _cachedCode = null;
    _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  static String countryName(String? code) =>
      ProxyNode.countryNames[code?.toUpperCase()] ?? code?.toUpperCase() ?? '未知';

  /// 结果缓存：连接成功后/切换节点会重复调用，10 分钟内命中直接返回，
  /// 避免每次用户动作都触发 1-2 次经隧道的外呼(ip-api 无 key 限 45/min)
  String? _cachedCode;
  DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _cacheTtl = Duration(minutes: 10);

  /// 走隧道查询真实出口国家码；失败返回 null（不阻塞连接流程）。
  /// [force] 切换节点/国家、重新连接后出口 IP 已变，须强制重查绕过 TTL 缓存
  /// —— 否则 10 分钟内一直返回旧国家，表现为「切了国家真实出口不变」。
  Future<String?> lookupViaProxy({bool force = false}) async {
    // 缓存命中（10min 内）直接返回；force 时跳过读缓存（仍会写入新结果）
    final now = DateTime.now();
    if (!force && _cachedCode != null && now.difference(_cachedAt) < _cacheTtl) {
      return _cachedCode;
    }
    // 读当前生效的本地代理端口（设置页可改）：出口定位必须走同一个 mixed
    // 入站，端口不匹配时请求会落到空端口导致定位失败
    int port = defaultPort;
    try {
      final s = await SettingsStore.instance.load();
      port = (s['localPort'] as num?)?.toInt() ?? defaultPort;
    } catch (_) {}
    Dio? dio;
    try {
      dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 6),
        headers: {'Accept': 'application/json'},
      ));
      // 显式走本地混合代理（App 自身请求默认不走系统代理）
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          c.connectionTimeout = const Duration(seconds: 5);
          c.findProxy = (uri) => 'PROXY 127.0.0.1:$port';
          return c;
        },
      );

      // 主：Cloudflare trace（返回 loc=US 行；anycast 全球边缘、无按 IP 配额）。
      // ip-api.com 免费额度是按「来源 IP」限 45 次/分钟，而这里的查询走隧道、
      // 来源是出口节点 IP —— 同节点全部用户共享配额，上量后必然 429 全挂。
      // Cloudflare 无此问题，故为主源；ip-api / ipinfo 降为备用。
      try {
        final r0 = await dio.get<String>(
          'https://www.cloudflare.com/cdn-cgi/trace',
          options: Options(responseType: ResponseType.plain),
        );
        final body = r0.data ?? '';
        final m = RegExp(r'^loc=([A-Za-z]{2})$', multiLine: true).firstMatch(body);
        final loc = m?.group(1)?.toUpperCase();
        // Cloudflare 定位不到时返回 loc=XX，视为无效落到备用源
        if (loc != null && loc != 'XX') {
          _cachedCode = loc;
          _cachedAt = DateTime.now();
          return _cachedCode;
        }
      } catch (_) {}
      // 备 1：ip-api.com（免费无需 key，按出口 IP 限 45/min）
      try {
        final r = await dio.get('http://ip-api.com/json?fields=countryCode,country');
        final d = r.data;
        if (d is Map && d['status'] == 'success' && d['countryCode'] != null) {
          _cachedCode = d['countryCode'].toString().toUpperCase();
          _cachedAt = DateTime.now();
          return _cachedCode;
        }
      } catch (_) {}
      // 备 2：ipinfo.io
      final r2 = await dio.get('https://ipinfo.io/json');
      final d2 = r2.data;
      if (d2 is Map && d2['country'] != null) {
        _cachedCode = d2['country'].toString().toUpperCase();
        _cachedAt = DateTime.now();
        return _cachedCode;
      }
    } catch (_) {
      // 定位失败不影响连接
    } finally {
      dio?.close(force: true);
    }
    return null;
  }
}
