import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../models/models.dart';

/// 真实出口国家检测：连接成功后，通过隧道（本地混合代理端口 2080）
/// 请求 IP 地理定位接口，返回**实际出口 IP 所在国家**——不是按节点名猜测。
class GeoLookupService {
  GeoLookupService._();
  static final GeoLookupService instance = GeoLookupService._();

  /// 本地混合代理端口（与 sing-box 配置 mixed-in 一致）
  static const _proxyPort = 2080;

  static String countryName(String? code) =>
      ProxyNode.countryNames[code?.toUpperCase()] ?? code?.toUpperCase() ?? '未知';

  /// 走隧道查询真实出口国家码；失败返回 null（不阻塞连接流程）
  Future<String?> lookupViaProxy() async {
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
          c.findProxy = (uri) => 'PROXY 127.0.0.1:$_proxyPort';
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
