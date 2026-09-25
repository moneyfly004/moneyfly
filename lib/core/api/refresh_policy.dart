/// 令牌刷新策略：把「刷新失败」分成**能自救**与**只能重新登录**两类。
/// （纯 Dart，无 Flutter 依赖，可单测。）
///
/// 背景（2026-09-25 工单：「软件无故退出，是不是后台踢的？」）：
/// 后台按设计允许同一账号多设备同时在线（无单会话限制），access token 有效期
/// 120 分钟、refresh 30 天，令牌只会因**显式登出**或**过期**失效。客户遇到的
/// 「无故退出」来自客户端：
///
///   `ApiClient._doRefresh()` 旧实现是 `catch (_) { return false; }` ——
///   **任何**失败（超时/DNS/连不上/代理节点不通/5xx/429…）都算「会话失效」，
///   于是 `onSessionExpired` → 登出 → 回登录页。access 每 120 分钟到期一次，
///   每次都要靠那一次刷新成功；客户大多开着代理，节点一抖就被登出。
///
/// 生产数据印证（后台 audit_logs，近 7 天）：
///   `security_auth_token_invalid` 6905 次，其中 `/api/v1/user/subscribe` 6159 次
///   （定时拉订阅正好撞上过期）；另有同设备 49 秒内两次登录的记录。
///
/// 因此这里定死语义：
///   - **rejected**：服务端明确拒绝（刷新接口 401/400：令牌失效/缺少令牌）
///     → 会话真的没了，登出是对的；
///   - **transient**：传输层或服务端**临时**故障 → 绝不允许据此登出，
///     退避重试后仍失败就如实报「网络异常」，把会话留给用户。
library;

import 'package:dio/dio.dart';

/// 刷新结果
enum RefreshOutcome {
  /// 拿到新令牌
  success,

  /// 服务端明确拒绝：只能重新登录
  rejected,

  /// 临时故障（网络/服务端过载）：**不要登出**
  transient,
}

/// 刷新失败时的最大尝试次数（含首次）
const int kRefreshMaxAttempts = 3;

/// 第 [attempt] 次重试前的等待（attempt 从 1 开始）：0.5s → 1.5s → 3s
Duration refreshBackoff(int attempt) {
  switch (attempt) {
    case 1:
      return const Duration(milliseconds: 500);
    case 2:
      return const Duration(milliseconds: 1500);
    default:
      return const Duration(seconds: 3);
  }
}

/// 刷新请求**成功返回（HTTP 2xx）**时，正文到底算不算「拿到了新令牌」。
///
/// 为什么不能把「200 但正文看不懂」也算成 rejected：网关/WAF/运营商拦截页、
/// 维护页、后端改字段名（`token` 而非 `access_token`）都会返回 200 + 非标准正文。
/// 判成 rejected 就是**登出**（旧实现如此，与本文件头描述的故障同族）；
/// 判成 transient 则只是退避重试 + 保留会话，客户最多多等几秒。
RefreshOutcome classifyRefreshSuccessBody(Object? data) {
  if (data is Map) {
    final token = data['access_token'];
    if (token != null && token.toString().isNotEmpty) {
      return RefreshOutcome.success;
    }
  }
  return RefreshOutcome.transient;
}

/// 只有「服务端明确拒绝」才终结会话。
bool shouldEndSession(RefreshOutcome outcome) =>
    outcome == RefreshOutcome.rejected;

/// 响应正文是否来自**本服务端**（统一 JSON 信封：`success` + `code` 两个字段）。
///
/// 用途：网关 / WAF / 维护页返回的 4xx 正文往往是 HTML、或别家网关的 JSON
/// （Cloudflare 拦截页、nginx 默认页…），它们**不代表**会话失效。
/// 只有正文确实是本服务端的信封时，才允许据状态码终结会话。
bool isAppErrorEnvelope(Object? data) {
  if (data is! Map) return false;
  return data.containsKey('success') && data.containsKey('code');
}

/// 把刷新接口的失败归类。
///
/// 判据用**HTTP 状态码**而不是异常文本：
///   - 401 / 400：服务端明确说令牌不可用（「刷新令牌已失效，请重新登录」/
///     「缺少刷新令牌」/「刷新令牌已过期」/「令牌类型错误」）→ rejected
///     （不重试，重试也没用）。这就是本服务端 `/auth/refresh` 的全部拒绝语义。
///   - **403：本服务端刷新接口从来不会返回 403**（见后端 handlers/auth.go 的
///     RefreshToken：只有 400/401）。命中 403 基本是 CDN/WAF/维护页/反代。
///     旧实现一律当「账户被禁用」→ 登出，与「无故退出」同族（主域名走
///     Cloudflare 时尤其容易命中）。现在只有正文是本服务端信封时才认账。
///   - 其它状态码（429/5xx/502/504…）：服务端可达但当前不可用 → transient；
///   - 没有 response（超时/连不上/DNS/TLS 失败）→ transient。
RefreshOutcome classifyRefreshError(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    if (status == 401 || status == 400) return RefreshOutcome.rejected;
    if (status == 403 && isAppErrorEnvelope(error.response?.data)) {
      return RefreshOutcome.rejected;
    }
    return RefreshOutcome.transient;
  }
  // 非 Dio 异常（本地存储读写失败等）：不据它登出，交给重试/下次再试
  return RefreshOutcome.transient;
}

/// 解析 JWT 的 `exp`（UTC）。解析不出来返回 null（不抛）。
///
/// 只做 base64url 解包读字段，不验签（验签是服务端的事）；用它可以**提前刷新**，
/// 避免等 401 再补 —— 那条路正是「一次抖动就登出」的来源。
DateTime? jwtExpiry(String? token) {
  if (token == null || token.isEmpty) return null;
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
    payload = payload.padRight((payload.length + 3) & ~3, '=');
    final decoded = String.fromCharCodes(base64Decode(payload));
    final exp = RegExp(r'"exp"\s*:\s*(\d+)').firstMatch(decoded);
    if (exp == null) return null;
    final secs = int.tryParse(exp.group(1)!);
    if (secs == null || secs <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
  } catch (_) {
    return null;
  }
}

/// base64 解码（url-safe，补 padding）——避免额外依赖。
List<int> base64Decode(String s) {
  const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final ch in s.split('')) {
    if (ch == '=') break;
    final v = table.indexOf(ch);
    if (v < 0) continue; // 容忍空白/换行
    buffer = (buffer << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xFF);
    }
  }
  return out;
}

/// 是否需要**提前刷新**（access token 剩余不足 [lead]）。
///
/// 解析不出 exp 时返回 false：宁可不提前刷，也不要在信息不足时乱发请求。
bool needsProactiveRefresh(
  String? accessToken, {
  Duration lead = const Duration(minutes: 10),
  DateTime? now,
}) {
  final exp = jwtExpiry(accessToken);
  if (exp == null) return false;
  final t = (now ?? DateTime.now()).toUtc();
  return exp.difference(t) <= lead;
}
