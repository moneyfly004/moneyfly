import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 服务器线路池：主域名连不上时自动轮换到备用域名。
///
/// 为什么需要（2026-09-23 线上问题）：官网域名在某些地区会被屏蔽，
/// 用户「登录不进去 / 更新不了订阅」——但同一套后端的其它域名在那些地区是可用的。
/// 本类维护一个域名池，配合 [ApiClient] 的失败重试拦截器实现：
///
///   1. 请求打当前域名；如果是**连接层失败**（超时/连不上，而不是 4xx/5xx 业务错误），
///      自动换池里下一个域名重试同一请求（登录、拉订阅地址、下单等全部受益）；
///   2. 成功的域名被记住（本地持久化），下次启动优先用它，避免每次都先撞墙；
///   3. 全部域名都失败时保持原状并如实报错，不掩盖真实错误。
///
/// 域名池里的地址都是同一套后端（token 通用、数据一致），所以换域名对用户完全透明。
/// 域名按既有约定做 XOR 混淆（同 `Endpoints.baseUrl` 的原实现），避免被简单的字符串扫描识别。
class ServerPool {
  ServerPool._();

  static final ServerPool instance = ServerPool._();

  /// 域名池（主域名在前）。每项都是「scheme://host/api/v1」形式的基底地址。
  static final List<String> domains = _decodeAll(const [
    // https://dy.moneyfly.top/api/v1 —— 主域名（官网）
    'Mi4uKilgdXU+I3Q3NTQ/Izw2I3QuNSp1OyozdSxr',
    // https://moneyfly.dpdns.org/api/v1
    'Mi4uKilgdXU3NTQ/Izw2I3Q+Kj40KXQ1KD11OyozdSxr',
    // https://sub.moneyfly.dpdns.org/api/v1
    'Mi4uKilgdXUpLzh0NzU0PyM8NiN0Pio+NCl0NSg9dTsqM3Usaw==',
    // https://new.moneyfly.dpdns.org/api/v1
    'Mi4uKilgdXU0Py10NzU0PyM8NiN0Pio+NCl0NSg9dTsqM3Usaw==',
  ]);

  static const _prefsKeyIndex = 'serverPoolIndex';
  static const _prefsKeyCustom = 'serverPoolCustomBase';

  static List<String> _decodeAll(List<String> encoded) => [
        for (final e in encoded)
          String.fromCharCodes([
            for (final c in base64.decode(e)) c ^ 0x5A,
          ]),
      ];

  int _index = 0;
  String _custom = '';
  bool _loaded = false;

  /// 池内域名（主域名在前）
  List<String> get all => List.unmodifiable(domains);

  /// 用户手动指定的域名基底（为空表示用池内域名）
  String get customBase => _custom;
  bool get usingCustom => _custom.isNotEmpty;

  /// 当前生效的基底地址（形如 https://xxx/api/v1）
  String get activeBase => _custom.isNotEmpty ? _custom : domains[_index];

  /// 当前生效域名的主机名（界面展示用）
  String get activeHost {
    final u = Uri.tryParse(activeBase);
    return u?.host ?? activeBase;
  }

  int get activeIndex => _index;

  /// 从本地恢复上次可用的线路（幂等，可重复调用）
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final idx = p.getInt(_prefsKeyIndex) ?? 0;
      if (idx >= 0 && idx < domains.length) _index = idx;
      _custom = (p.getString(_prefsKeyCustom) ?? '').trim();
    } catch (_) {
      // 读取失败按默认（主域名）处理，不影响使用
    }
  }

  /// 记录某个基底可用：切换过去并持久化（下次启动优先使用）
  Future<void> markWorking(String base) async {
    final normalized = normalizeBase(base);
    if (normalized.isEmpty) return;
    final i = domains.indexOf(normalized);
    if (i >= 0) {
      _index = i;
      _custom = '';
    } else {
      _custom = normalized;
    }
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_prefsKeyIndex, _index);
      await p.setString(_prefsKeyCustom, _custom);
    } catch (_) {}
  }

  /// 返回下一个**尚未尝试过**的基底；均已尝试过则返回 null。
  ///
  /// [tried] 是本次请求已尝试过的基底列表（由重试拦截器维护），
  /// 这样一轮重试里每个域名只会被打一次。
  String? nextUntried(List<String> tried) {
    final candidates = _custom.isNotEmpty ? <String>[_custom, ...domains] : domains;
    for (var step = 1; step <= candidates.length; step++) {
      final candidate = candidates[(_index + step) % candidates.length];
      if (!tried.contains(candidate)) return candidate;
    }
    return null;
  }

  /// 恢复为「优先主域名、不指定自定义域名」
  Future<void> reset() async {
    _index = 0;
    _custom = '';
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_prefsKeyIndex, 0);
      await p.remove(_prefsKeyCustom);
    } catch (_) {}
  }

  /// 用户手动指定域名（可只填域名，自动补 https:// 与 /api/v1）
  Future<void> setCustom(String input) async {
    final normalized = normalizeBase(input);
    if (normalized.isEmpty) return;
    await markWorking(normalized);
  }

  Future<void> clearCustom() async {
    _custom = '';
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_prefsKeyCustom);
    } catch (_) {}
  }

  /// 主机是否为回环地址或私有网段 —— 这些地址上的明文 http 可以接受
  /// （内网自建面板、本机调试），因为它们不出公网。
  static bool isLoopbackOrPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    if (h == '::1' || h.startsWith('fe80:') || h.startsWith('fc') ||
        h.startsWith('fd')) {
      return true; // IPv6 回环 / 链路本地 / ULA
    }
    final p = h.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]);
    final b = int.tryParse(p[1]);
    if (a == null || b == null) return false;
    if (a == 127 || a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 169 && b == 254) return true;
    return false;
  }

  /// 把用户输入规整成基底地址：
  /// `example.com` → `https://example.com/api/v1`；`https://x/api/v1/` → `https://x/api/v1`
  ///
  /// 公网主机**只接受 https**：令牌是 Bearer 明文头，走 http 会被中间人直接拿走
  /// （账号密码、订阅链接同理）。回环/私有网段仍允许 http，方便内网自建服务器。
  /// 公网 http（以及非 http(s) 的 scheme）一律返回空串，由调用方按「地址无效」拒绝。
  static String normalizeBase(String input) {
    var v = input.trim();
    if (v.isEmpty) return '';
    if (!v.contains('://')) v = 'https://$v';
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    v = v.replaceAll(RegExp(r'/+$'), '');
    // 只给了主机名（或带路径但不是 /api/v1）时补上接口前缀
    final u = Uri.tryParse(v);
    if (u == null || u.host.isEmpty) return '';
    final scheme = u.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return '';
    if (scheme == 'http' && !isLoopbackOrPrivateHost(u.host)) return '';
    final path = u.path.replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty) {
      // 用 authority（含端口）而不是 host：否则 `http://host:8000` 会被重建为
      // `http://host/api/v1`，端口丢失 → 自建服务器在非标准端口上必然连错。
      return '${u.scheme}://${u.authority}/api/v1';
    }
    return v;
  }

  /// 判断异常是否为「连接层失败」——只有这类错误才值得换域名重试。
  ///
  /// 4xx/5xx 是服务端**能连上但明确回复**的结果（密码错、token 失效、限流等），
  /// 换域名毫无意义，还会把业务错误掩盖成网络错误，所以这里一律返回 false。
  static bool isConnectionFailure(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.connectionError:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return true;
        default:
          // 有响应 = 服务端可达；无响应且类型未知时按连接失败处理（保守重试一次）
          if (error.response != null) return false;
          return error.error is SocketException ||
              error.error is HandshakeException ||
              error.message?.toLowerCase().contains('socket') == true;
      }
    }
    return error is SocketException || error is HandshakeException;
  }

  /// 该请求在换域名后是否可以安全重试。
  ///
  /// 不能对所有失败一律重试：**请求可能已经在服务端执行过**（例如下单、签到、
  /// 领取优惠券），重试会造成重复执行。因此按「连接是否建立」和「方法是否幂等」区分：
  ///
  ///   - `connectionError` / `connectionTimeout`：压根没连上 → 任何方法都可安全重试；
  ///   - `sendTimeout` / `receiveTimeout`：连接已建立、请求可能已送达服务端 →
  ///     只对幂等方法（GET/HEAD/OPTIONS）重试，写操作交给上层如实报错。
  static bool isRetryableOnRotation(Object error, String method,
      {String? path}) {
    // 刷新令牌**绝不换域名重试**：该接口一旦成功就会轮换并拉黑旧 refresh_token，
    // 若第一次已成功而响应在途中丢失，换域名拿同一个旧 token 再刷必然 401
    // 「刷新令牌已失效」→ 反而把用户登出（见 refresh_policy.dart）。
    if (path != null && path.contains('/auth/refresh')) return false;
    if (!isConnectionFailure(error)) return false;
    final m = method.toUpperCase();
    final idempotent = m == 'GET' || m == 'HEAD' || m == 'OPTIONS';
    if (idempotent) return true;
    if (error is! DioException) return false;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout;
  }
}

/// 构造「域名轮换」Dio 拦截器。
///
/// 抽成独立函数是为了可测试：测试里挂到自己的 Dio 上，注入一个"主域名必失败、
/// 备用域名成功"的 adapter，即可验证整条切换链路（见 test/server_pool_test.dart）。
///
/// 行为：
///   - 连接层失败（超时/连不上）→ 依次换域名池里**尚未试过**的域名重试同一请求；
///     全部失败才把最后一次错误抛给上层（不掩盖真实错误）；
///   - 4xx/5xx（服务端可达但明确回复）→ 原样抛出，不换域名；
///   - 任一请求成功 → 记住该域名（下次启动优先生效）。
///
/// 注意：重试用 `dio.fetch(options)`，它不会再走一遍拦截器，所以不存在递归风险。
/// [dio] 是挂载该拦截器的实例：重试需要用它发请求（`dio.fetch` 不走拦截器，无递归风险）。
Interceptor buildServerFailoverInterceptor(Dio dio,
    {void Function(String message)? onLog}) {
  return InterceptorsWrapper(
    onResponse: (r, h) {
      final base = r.requestOptions.baseUrl;
      if (base.isNotEmpty && base != ServerPool.instance.activeBase) {
        unawaited(ServerPool.instance.markWorking(base));
      }
      h.next(r);
    },
    onError: (e, h) async {
      final opts = e.requestOptions;
      // 请求方显式声明「不要换域名重试」（如 /auth/refresh：换了反而会把用户登出）
      if (opts.extra['_noDomainFailover'] == true) {
        h.next(e);
        return;
      }
      // 写操作只在"压根没连上"时重试，避免服务端已执行过又被重试（重复下单/签到）
      if (!ServerPool.isRetryableOnRotation(e, opts.method, path: opts.path)) {
        h.next(e);
        return;
      }
      final tried = <String>[
        ...?(opts.extra['_domainTried'] as List?)?.map((v) => v.toString()),
      ];
      final current =
          opts.baseUrl.isNotEmpty ? opts.baseUrl : ServerPool.instance.activeBase;
      if (!tried.contains(current)) tried.add(current);
      opts.extra['_domainTried'] = tried;

      Object lastError = e;
      while (true) {
        final next = ServerPool.instance.nextUntried(tried);
        if (next == null) break; // 池内域名都试过了 → 如实报错
        tried.add(next);
        opts.extra['_domainTried'] = tried;
        opts.baseUrl = next;
        onLog?.call('[线路切换] $current 连接失败（${e.type}）→ 改试 $next');
        try {
          final retried = await dio.fetch(opts);
          unawaited(ServerPool.instance.markWorking(next));
          h.resolve(retried);
          return;
        } catch (e2) {
          lastError = e2 is DioException ? e2 : e;
          if (!ServerPool.isRetryableOnRotation(lastError, opts.method,
              path: opts.path)) {
            break;
          }
        }
      }
      h.next(lastError is DioException ? lastError : e);
    },
  );
}
