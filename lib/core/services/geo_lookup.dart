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

  static String countryName(String? code) =>
      ProxyNode.countryNames[code?.toUpperCase()] ?? code?.toUpperCase() ?? '未知';

  /// 走隧道查询真实出口国家码；失败返回 null（不阻塞连接流程）
  Future<String?> lookupViaProxy() async {
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

      // 主：ip-api.com（免费无需 key）；备：ipinfo.io
      try {
        final r = await dio.get('http://ip-api.com/json?fields=countryCode,country');
        final d = r.data;
        if (d is Map && d['status'] == 'success' && d['countryCode'] != null) {
          return d['countryCode'].toString().toUpperCase();
        }
      } catch (_) {}
      final r2 = await dio.get('https://ipinfo.io/json');
      final d2 = r2.data;
      if (d2 is Map && d2['country'] != null) {
        return d2['country'].toString().toUpperCase();
      }
    } catch (_) {
      // 定位失败不影响连接
    } finally {
      dio?.close(force: true);
    }
    return null;
  }
}
