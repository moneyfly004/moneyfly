import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'endpoints.dart';

/// 统一 API 客户端
/// 后端所有接口（除 XBoard 兼容与订阅原文外）返回信封：
/// { success, code, message, data, timestamp, request_id }
/// 本客户端统一解包：get/post/put/delete 直接返回 data（dynamic），
/// 无信封时（XBoard 兼容接口）返回整个响应体。
class ApiClient {
  /// 测试注入点：在测试中替换为 mock Dio（需在使用 ApiClient 之前设置）
  static Dio? debugDio;

  ApiClient._internal() {
    _dio = debugDio ?? Dio(BaseOptions(
      baseUrl: Endpoints.baseUrl,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
      sendTimeout: const Duration(seconds: 15),
      headers: {'Accept': 'application/json', 'User-Agent': userAgent},
    ));
    if (debugDio != null) return; // 测试环境：跳过 JWT 拦截器
    // 请求日志（写入 App Support 目录 http.log，登录/网络问题排查用）
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        _logHttp('>>> ${o.method} ${o.uri}\n    body: ${o.data}');
        h.next(o);
      },
      onResponse: (r, h) {
        final body = r.data is String ? (r.data as String) : (r.data?.toString() ?? '');
        _logHttp('<<< ${r.statusCode} ${r.requestOptions.uri}\n    body: ${body.length > 400 ? body.substring(0, 400) : body}');
        h.next(r);
      },
      onError: (e, h) {
        _logHttp('!!! ${e.type} ${e.requestOptions.uri} status=${e.response?.statusCode}\n    err: $e\n    resp: ${e.response?.data}');
        h.next(e);
      },
    ));
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final t = await readAccessToken();
          if (t != null && t.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $t';
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          final resp = e.response;
          if (resp?.statusCode == 401 && e.requestOptions.extra['_retried'] != true) {
            e.requestOptions.extra['_retried'] = true;
            final ok = await _tryRefresh();
            if (ok) {
              final t = await readAccessToken();
              e.requestOptions.headers['Authorization'] = 'Bearer $t';
              try {
                final retried = await _dio.fetch(e.requestOptions);
                return handler.resolve(retried);
              } on DioException catch (e2) {
                return handler.next(e2);
              } catch (_) {
                return handler.next(e);
              }
            } else {
              _onSessionExpired?.call();
            }
          }
          handler.next(e);
        },
      ),
    );
  }

  static ApiClient? _instance;

  static ApiClient get instance => _instance ??= ApiClient._internal();

  /// 测试专用：重置单例，使下一次访问使用新的 debugDio
  @visibleForTesting
  static void resetInstance() => _instance = null;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 客户端 User-Agent：MoneyFly/<版本>（后端据此识别为 moneyfly 客户端，
  /// 设备列表/登录历史会显示 MoneyFly；由 UpdateService.init 在启动时更新）
  static String userAgent = 'MoneyFly/0.0.1';

  /// 测试开关：false 时 token 存内存（避免 flutter test 无插件实现）
  static bool persistTokens = true;
  static String? _memAccess;
  static String? _memRefresh;

  late final Dio _dio;
  VoidCallback? _onSessionExpired;
  Future<bool>? _refreshing;

  // ---------- Token 存取 ----------
  static Future<String?> readAccessToken() async {
    if (_memAccess != null) return _memAccess;
    if (!persistTokens) return null;
    try {
      return await _storage.read(key: 'access_token');
    } catch (_) {
      return null;
    }
  }

  static Future<String?> readRefreshToken() async {
    if (_memRefresh != null) return _memRefresh;
    if (!persistTokens) return null;
    try {
      return await _storage.read(key: 'refresh_token');
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveTokens(String access, String refresh) async {
    _memAccess = access;
    _memRefresh = refresh;
    if (!persistTokens) return;
    // 存储失败（如 macOS Keychain 异常）不阻塞登录：内存 token 仍可用
    try {
      await _storage.write(key: 'access_token', value: access);
      await _storage.write(key: 'refresh_token', value: refresh);
    } catch (e) {
      _logHttp('!!! token 持久化失败（内存兜底）: $e');
    }
  }

  static Future<void> clearTokens() async {
    _memAccess = null;
    _memRefresh = null;
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'refresh_token');
  }

  /// 会话失效回调（强制回登录页）
  void onSessionExpired(VoidCallback cb) => _onSessionExpired = cb;

  /// 并发 401 去重：同一时刻只允许一个刷新请求在途
  Future<bool> _tryRefresh() =>
      _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<bool> _doRefresh() async {
    final rt = await readRefreshToken();
    if (rt == null || rt.isEmpty) return false;
    try {
      final r = await _dio.post(Endpoints.refresh, data: {'refresh_token': rt});
      final data = _unwrap(r.data);
      if (data is Map && data['access_token'] != null) {
        await saveTokens(
          data['access_token'].toString(),
          (data['refresh_token'] as String?) ?? rt,
        );
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 追加一行到 HOME/Library/Application Support/top.moneyfly.app/http.log
  static void _logHttp(String line) {
    if (kIsWeb) return;
    try {
      final home = Platform.environment['HOME'] ?? '/tmp';
      final logDir = Directory('$home/Library/Application Support/top.moneyfly.app');
      if (!logDir.existsSync()) logDir.createSync(recursive: true);
      final f = File('${logDir.path}/http.log');
      f.writeAsStringSync('[${DateTime.now().toIso8601String()}] $line\n', mode: FileMode.append);
    } catch (_) {}
  }

  // ---------- 统一解包 ----------
  /// 后端业务错误（success:false）：抛出携带 message 的异常，
  /// 由 errorMsg() 归一化为中文提示，避免服务层拿到 null 后抛 TypeError
  static dynamic _unwrap(dynamic body) {
    if (body is Map && body['success'] == false) {
      final msg = body['message'] ?? body['error'] ?? body['detail'];
      throw ApiException(msg?.toString() ?? '请求失败，请稍后重试');
    }
    if (body is Map && body['success'] == true && body.containsKey('data')) {
      return body['data'];
    }
    // 兼容 success 缺失但带 data 的信封 / XBoard 原始返回
    if (body is Map && body.containsKey('data')) return body['data'];
    return body;
  }

  /// GET：返回解包后的 data
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final r = await _dio.get(path, queryParameters: query);
    return _unwrap(r.data);
  }

  /// POST：返回解包后的 data；raw=true 时返回原始响应体
  Future<dynamic> post(String path, {Object? data, bool raw = false}) async {
    final r = await _dio.post(path, data: data);
    return raw ? r.data : _unwrap(r.data);
  }

  Future<dynamic> put(String path, {Object? data}) async {
    final r = await _dio.put(path, data: data);
    return _unwrap(r.data);
  }

  Future<dynamic> delete(String path, {Object? data}) async {
    final r = await _dio.delete(path, data: data);
    return _unwrap(r.data);
  }

  /// 拉取订阅原文（非 JSON）
  /// 订阅 URL 已带 type=clash 参数 → 后端按参数返回 Clash YAML；
  /// UA 用 MoneyFly/<版本>（后端原生识别 moneyfly 客户端）
  Future<String> fetchText(String url) async {
    final r = await _dio.getUri(Uri.parse(url));
    return r.data?.toString() ?? '';
  }

  // ---------- 错误归一化 ----------
  static String errorMsg(Object e) {
    if (e is ApiException) return e.message;
    if (e is DioException) {
      final d = e.response?.data;
      if (d is Map) {
        final msg = d['message'] ?? d['detail'] ?? d['error'];
        if (msg != null && msg.toString().isNotEmpty) return msg.toString();
      }
      if (d is String && d.isNotEmpty) return d;
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.connectionError:
          return '网络连接失败，请检查网络后重试';
        case DioExceptionType.receiveTimeout:
          return '服务器响应超时，请稍后重试';
        case DioExceptionType.sendTimeout:
          return '发送请求超时，请稍后重试';
        case DioExceptionType.cancel:
          return '请求已取消';
        default:
          final code = e.response?.statusCode;
          if (code == 401) return '登录已过期，请重新登录';
          if (code == 403) return '没有权限执行此操作';
          if (code == 404) return '请求的资源不存在';
          if (code == 429) return '操作过于频繁，请稍后再试';
          if (code == 500) return '服务器开小差了，请稍后重试';
          return '请求失败（${code ?? '未知'}）';
      }
    }
    if (e is FormatException) return '数据解析失败';
    return e.toString();
  }
}

/// 后端业务错误异常（success:false 信封）
class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}
