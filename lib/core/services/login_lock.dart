/// 服务端限流 / 锁定的识别与文案（纯 Dart，仅依赖 dio，可单测）。
///
/// 背景（客服工单 2026-09-23：「客户登录失败次数过多，账号锁定或者 ip 锁定」）：
/// 后端 cboard-go 有两套防爆破机制，**返回的都是 HTTP 429**，但含义完全不同：
///
/// 1) 按 IP + 路径的分钟级限流（`internal/api/middleware/ratelimit.go`，挂在
///    `internal/api/router/router.go` 上）：
///      POST /auth/login        → 10 次/分钟
///      POST /auth/refresh      → 10 次/分钟
///      POST /auth/verification/send → 3 次/分钟
///      POST /auth/forgot-password   → 3 次/分钟
///      超限响应：`{"code":42900,"message":"请求过于频繁，请稍后再试"}`（不带头）。
///    这是「同一网络短时间请求太多」——等一分钟或换个网络立刻就能用。
///
/// 2) 按「登录名 + IP」的失败锁定（`internal/api/handlers/auth.go`）：
///      max_login_attempts（默认 5）/ login_lockout_minutes（默认 30），任一为 0 即关闭。
///      超限响应：429 + `Retry-After: <剩余秒>` +
///      `{"code":42900,"message":"登录失败次数过多，请 30 分钟后再试"}`。
///    （2026-09-23 线上实测：该开关当前是**关闭**的 —— 库里的
///     `max_login_attempts=2000`、`login_lockout_minutes=0`，所以客户遇到的
///     其实几乎都是第 1 种限流，而不是账号锁定。）
///
/// 为什么客户端必须专门提示：这两种情况下**密码是对的**，用户却怎么都登不进，
/// 只会反复点登录 —— 而反复点正是让限流一直不解除的原因。旧实现只把服务端那句
/// 话当普通 toast 弹一下，既没说清是「账号锁了」还是「网络被限流」，也没有等待
/// 倒计时和「怎么办」，用户只能干瞪眼或不停重试。
library;

import 'package:dio/dio.dart';

/// 业务错误码：后端 `utils.TooManyRequests` 固定用 42900
const int kRateLimitCode = 42900;

/// 限流命中的接口类型（决定文案里的建议）
enum RateLimitScope {
  /// 登录
  login,

  /// 刷新令牌（用户看不到，通常是 App 内部触发）
  refresh,

  /// 验证码发送 / 校验 / 找回密码
  verification,

  /// 其它接口
  other,
}

/// 一次限流/锁定的完整信息
class RateLimitInfo {
  const RateLimitInfo({
    required this.message,
    required this.scope,
    this.retryAfter,
    this.isAccountLock = false,
  });

  /// 服务端原文（尽量原样展示，客服据此对号入座）
  final String message;

  final RateLimitScope scope;

  /// `Retry-After` 头解析出的剩余时间（服务端只有「失败锁定」那条路径会带）
  final Duration? retryAfter;

  /// 是否属于「登录失败次数过多」这类账号维度锁定（区别于纯 IP 限流）
  final bool isAccountLock;

  /// 建议的本地按钮冷却时长。
  ///
  /// 只做「挡住连点」这一件事，**不**等于服务端的锁定时间：
  ///   - 服务端锁是按「IP(+账号)」算的，用户换个网络（WiFi ↔ 移动数据）本来就能
  ///     立刻登录；把按钮按真实锁定时长（可能 15 分钟）锁死，反而把人挡在门外。
  ///   - 连点才是让计数器一直不归零、锁定一直续期的元凶，所以 30~120s 足够。
  /// 真实等待时长由 [retryAfter] 在弹窗里如实告诉用户，并提供「我已换网络，重试」。
  Duration get cooldown {
    final ra = retryAfter;
    if (ra == null || ra <= Duration.zero) return const Duration(seconds: 60);
    if (ra < const Duration(seconds: 30)) return const Duration(seconds: 30);
    if (ra > const Duration(minutes: 2)) return const Duration(minutes: 2);
    return ra;
  }
}

/// 判定一段服务端文案是否属于限流/锁定类
/// （用于兜底：某些路径拿不到状态码，只能看 message）
bool looksLikeRateLimitMessage(String msg) {
  final m = msg.toLowerCase();
  const zh = ['次数过多', '过于频繁', '频率过高', '稍后再试', '请稍后重试', '已锁定', '锁定'];
  const en = [
    'too many',
    'rate limit',
    'ratelimit',
    'try again later',
    'too frequent',
    'locked',
    'temporarily blocked',
  ];
  return zh.any(m.contains) || en.any(m.contains);
}

/// 是否属于「失败次数过多」的账号维度锁定（比纯 IP 限流更严重，需要等更久）
bool _looksLikeAccountLock(String msg) {
  final m = msg.toLowerCase();
  return m.contains('锁定') || m.contains('locked') || m.contains('次数过多');
}

/// 从 Dio 响应头解析 `Retry-After`（支持秒数与 HTTP 日期两种写法）。
Duration? parseRetryAfter(Object? rawValue) {
  if (rawValue == null) return null;
  final raw = rawValue.toString().trim();
  if (raw.isEmpty) return null;
  final secs = int.tryParse(raw);
  if (secs != null) {
    return secs <= 0 ? Duration.zero : Duration(seconds: secs);
  }
  try {
    final when = HttpDateParser.tryParse(raw);
    if (when == null) return null;
    final diff = when.difference(DateTime.now().toUtc());
    return diff.isNegative ? Duration.zero : diff;
  } catch (_) {
    return null;
  }
}

/// HTTP 日期解析（`Retry-After` 也允许这种写法）。
/// 只认 IMF-fixdate（`Wed, 21 Oct 2015 07:28:00 GMT`）这一种，够用且无依赖。
class HttpDateParser {
  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  static DateTime? tryParse(String s) {
    // Wed, 21 Oct 2015 07:28:00 GMT
    final m = RegExp(r'^[A-Za-z]{3},\s*(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+'
            r'(\d{2}):(\d{2}):(\d{2})\s+GMT$')
        .firstMatch(s.trim());
    if (m == null) return null;
    final mon = _months[m.group(2)!.toLowerCase()];
    if (mon == null) return null;
    return DateTime.utc(
      int.parse(m.group(3)!),
      mon,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }
}

/// 根据请求路径判断限流范围
RateLimitScope scopeForPath(String? path) {
  final p = (path ?? '').toLowerCase();
  if (p.contains('/auth/login')) return RateLimitScope.login;
  if (p.contains('/auth/refresh')) return RateLimitScope.refresh;
  if (p.contains('verification') ||
      p.contains('forgot-password') ||
      p.contains('reset-password')) {
    return RateLimitScope.verification;
  }
  return RateLimitScope.other;
}

/// 从响应头解析等待时长。
///
/// 两种真实来源（dy.moneyfly.top 后端实测）：
///   - `Retry-After: <秒>`（cboard 的失败锁定路径）；
///   - `X-RateLimit-Reset: Wed, 21 Oct 2015 07:28:00 GMT`（`LoginRateLimitMiddleware`
///     在「还没进入锁定」的 429 分支会带）。
Duration? _waitFromHeaders(Headers? h) {
  if (h == null) return null;
  final ra = parseRetryAfter(h.value('retry-after'));
  if (ra != null && ra > Duration.zero) return ra;
  final reset = h.value('x-ratelimit-reset');
  if (reset != null && reset.trim().isNotEmpty) {
    final when = HttpDateParser.tryParse(reset);
    if (when != null) {
      final d = when.difference(DateTime.now().toUtc());
      if (!d.isNegative) return d;
    }
  }
  return null;
}

/// 从服务端**文案**里抠出等待时长。
///
/// 该后端把时长直接写进文案（没有头）：
///   「登录失败次数过多，账户已被临时锁定15分钟，请稍后再试」
///   「验证码尝试次数过多，请5分钟后再试」/「发送频率过高，请 5 分钟后再试」
/// 抠不出来时返回 null（文案会原样展示，不影响提示本身）。
Duration? parseWaitFromMessage(String msg) {
  final m = RegExp(r'(\d+)\s*(秒|分钟|分|小时|minutes?|mins?|min|seconds?|secs?|sec|hours?|hrs?|hr)',
          caseSensitive: false)
      .firstMatch(msg);
  if (m == null) return null;
  final n = int.tryParse(m.group(1)!);
  if (n == null || n <= 0) return null;
  final unit = m.group(2)!.toLowerCase();
  if (unit.startsWith('秒') || unit.startsWith('sec')) return Duration(seconds: n);
  if (unit.startsWith('小时') || unit.startsWith('hour') || unit.startsWith('hr')) {
    return Duration(hours: n);
  }
  return Duration(minutes: n);
}

/// 从任意异常里解析限流/锁定信息；不是限流则返回 null。
///
/// 判定顺序：
///   1) DioException 且 HTTP 429 → 限流（再看 body.code/message 细分账号锁定）；
///   2) 响应体 code == 42900（后端固定的限流业务码）→ 限流；
///   3) 兜底：异常文案命中限流关键词（部分平台/代理会把 429 改写成 200 + 文案）；
///   4) 其余返回 null（密码错误、网络不通等交给原有分支处理）。
RateLimitInfo? parseRateLimit(Object error, {String? path}) {
  final scope = scopeForPath(path);

  if (error is DioException) {
    final resp = error.response;
    final status = resp?.statusCode;
    final data = resp?.data;
    String? msg;
    int? code;
    if (data is Map) {
      final m = data['message'] ?? data['detail'] ?? data['error'];
      if (m != null) msg = m.toString();
      final c = data['code'];
      if (c is num) code = c.toInt();
      if (c is String) code = int.tryParse(c);
    } else if (data is String && data.trim().isNotEmpty) {
      msg = data.trim();
    }

    final isLimit = status == 429 || code == kRateLimitCode;
    if (isLimit) {
      final text = (msg == null || msg.trim().isEmpty)
          ? '请求过于频繁，请稍后再试'
          : msg.trim();
      return RateLimitInfo(
        message: text,
        scope: scope,
        // 顺序：Retry-After → X-RateLimit-Reset → 从文案里抠（后端只写了文案）
        retryAfter: _waitFromHeaders(resp?.headers) ?? parseWaitFromMessage(text),
        isAccountLock: _looksLikeAccountLock(text),
      );
    }
    // 429 之外：拿不到状态码时靠文案兜底（但仅限非登录失败语义）
    if (msg != null && looksLikeRateLimitMessage(msg)) {
      return RateLimitInfo(
        message: msg,
        scope: scope,
        isAccountLock: _looksLikeAccountLock(msg),
      );
    }
    return null;
  }

  // 非 Dio 异常：ApiException / 普通 Exception，只能看文案
  final text = _messageOf(error);
  if (looksLikeRateLimitMessage(text)) {
    return RateLimitInfo(
      message: text,
      scope: scope,
      retryAfter: parseWaitFromMessage(text),
      isAccountLock: _looksLikeAccountLock(text),
    );
  }
  return null;
}

/// 取异常的 message（`ApiException` 有 message 字段；普通 Exception 用 toString）。
/// 这里用 dynamic 取值而不是 import ApiClient —— 避免「接口层 ↔ 服务层」循环依赖，
/// 同时保持纯函数可单测（不需要构造真的 ApiException）。
String _messageOf(Object error) {
  try {
    final dynamic d = error;
    final m = d.message;
    if (m != null && m.toString().trim().isNotEmpty) return m.toString();
  } catch (_) {}
  return error.toString();
}

/// 剩余时间的人类可读文案：`90s` → `1 分 30 秒`、`45s` → `45 秒`、≤0 → 空串
String formatRemaining(Duration d) {
  final s = d.inSeconds;
  if (s <= 0) return '';
  if (s < 60) return '$s 秒';
  final m = s ~/ 60;
  final rest = s % 60;
  if (rest == 0) return '$m 分钟';
  return '$m 分 $rest 秒';
}
