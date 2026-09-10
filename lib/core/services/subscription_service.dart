import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';

import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';
import 'subscription_cache.dart';

/// 订阅服务：拉取订阅信息 → 获取 Clash YAML → 解析节点列表
///
/// 数据流（对应「运行拉取订阅并覆盖旧配置」要求）：
/// - 每次成功从网络拉取订阅 → 覆盖写入本地磁盘缓存（[SubscriptionCache]）
///   与内存缓存；
/// - 网络失败 → 回退读取本安装/本版本的有效本地缓存，保证登录后拿不到
///   节点时至少能看到最近一次成功拉到的线路（离线兜底，绝不静默空白）；
/// - 登出/切号 → [clearCache] 同时清内存与磁盘缓存，杜绝旧账号节点残留。
class SubscriptionService {
  SubscriptionService._();
  static final SubscriptionService instance = SubscriptionService._();

  List<ProxyNode> _cache = [];
  DateTime _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const _cacheTtl = Duration(minutes: 30);

  /// 最近一次成功拉取订阅的时间（首页「节点更新于 xx:xx」展示用）
  DateTime? get lastUpdatedAt {
    final t = _cacheTime;
    return t.millisecondsSinceEpoch <= 0 ? null : t;
  }

  /// 清缓存/登出代次：拉取在途期间登出 → 结果作废，禁止把旧账号数据写回
  /// 内存或磁盘缓存（防止登出竞态让旧缓存"复活"到下一个账号）
  int _epoch = 0;

  /// 登出/切号时清空节点缓存（内存 + 磁盘），避免旧账号节点残留到新账号
  void clearCache() {
    _epoch++;
    _cache = [];
    _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(SubscriptionCache.instance.clear());
  }

  /// 冷启动即时展示用：只读本地磁盘缓存并解析出节点，**不发任何网络请求**、
  /// 不改内存缓存/时间戳/代次。首页冷启动先用它秒显上次的线路（避免弱网下
  /// 干等 fetchInfo → 首页转圈/空白），随后由 fetchNodes(force:true) 后台
  /// 刷新覆盖。返回空列表表示无有效缓存（无缓存 / 版本过期 / 换号失效，
  /// 失效判定与删除由 SubscriptionCache.readLatest 内部完成）。
  ///
  /// 注意：这里读到的缓存**不经过账号门禁判定**（到期/禁用），因此仅用于
  /// UI 即时展示；真正能否连接仍由 AccountService 门禁 + fetchNodes 决定，
  /// 受限账号的 applySubscriptionNodes([]) 会清空展示，不会放行旧线路。
  Future<List<ProxyNode>> loadCachedNodes() async {
    try {
      final cached = await SubscriptionCache.instance.readLatest();
      if (cached == null || cached.raw.isEmpty) return const [];
      return await compute(_parseInIsolate, cached.raw);
    } catch (_) {
      return const [];
    }
  }

  /// 获取订阅信息（XBoard 兼容 /user/subscribe）
  Future<SubscriptionInfo> fetchInfo() async {
    final data = await ApiClient.instance.get(Endpoints.userSubscribe);
    if (data is! Map) {
      return SubscriptionInfo(
        subscribeUrl: '',
        deviceLimit: 0,
        currentDevices: 0,
        remainingDays: 0,
        isExpired: true,
        isActive: false,
        status: '',
      );
    }
    return SubscriptionInfo.fromJson(Map<String, dynamic>.from(data));
  }

  /// 获取并解析节点列表（带 30 分钟内存缓存，force 强制刷新）。
  ///
  /// 账号可用性前置判定（重点修复「到期/禁用后仍加载旧配置」）：
  /// - 账号受限（到期 / 订阅被停用 / 账号被禁用）→ **先于任何缓存**清空
  ///   内存与磁盘缓存并返回空列表：更新订阅加载的是「失效状态」，绝不加载
  ///   到期前拉到并存下来的老配置，也绝不回退本地磁盘缓存；
  /// - 账号正常：force 刷新 → 成功覆盖内存与磁盘缓存；网络/后端失败 →
  ///   回退本地缓存（仅当缓存属于当前安装且版本匹配），保证「运行即拉新
  ///   订阅覆盖旧配置」，断网时也不至于登录后一片空白。
  Future<List<ProxyNode>> fetchNodes({bool force = false}) async {
    final epoch = _epoch;
    try {
      final info = await fetchInfo();
      if (info.subscribeUrl.isEmpty) return [];
      if (!info.hasSubscription) {
        // 到期 / 订阅被停用 / 状态异常：清空缓存，加载「失效」而非老配置
        _dropAllCaches();
        return [];
      }
      // 账号正常且内存缓存仍在 30 分钟 TTL 内 → 直接返回缓存
      // （判定放在缓存命中之前：禁止用「到期前的缓存」跳过到期判定）
      if (!force &&
          _cache.isNotEmpty &&
          DateTime.now().difference(_cacheTime) < _cacheTtl) {
        return List.of(_cache);
      }
      return await _pullAndCache(info, epoch);
    } catch (e) {
      final msg = ApiClient.errorMsg(e);
      // 账号被禁用：后端业务接口统一 403「账户已被禁用…」→ 视为受限，
      // 清空缓存返回空，避免把禁用误当网络错误后回退到老配置
      if (_isDisableMessage(msg)) {
        _dropAllCaches();
        return [];
      }
      // 设备被踢下线：后端对「被删除设备的订阅请求」返回 403
      // 「此设备已被移除并踢下线…」→ 清空本地订阅缓存（该设备不能再
      // 使用任何旧配置），断开与提示由调用方（UI / 调度器）处理
      if (isKickedMessage(msg)) {
        _dropAllCaches();
      }
      // 其余失败（断网/超时/服务端异常）：缓存新鲜（TTL 内）时回退内存缓存，
      // 保证离线不丢已拉到的线路；缓存过期则按原错误抛出由调用方提示
      if (!force &&
          _cache.isNotEmpty &&
          DateTime.now().difference(_cacheTime) < _cacheTtl) {
        return List.of(_cache);
      }
      rethrow;
    }
  }

  /// 错误文案是否命中「设备被踢下线」（后端删除设备后的订阅 403 提示）。
  /// 供 UI/调度器识别后断开连接、清空节点并提示用户。
  static bool isKickedMessage(String msg) =>
      msg.contains('已被移除') ||
      msg.contains('踢下线') ||
      msg.toLowerCase().contains('removed') ||
      msg.toLowerCase().contains('kicked');

  /// 拉取订阅原文 → 后台解析 → 校验 epoch 后覆盖内存与磁盘缓存
  Future<List<ProxyNode>> _pullAndCache(
      SubscriptionInfo info, int epoch) async {
    final raw = await _fetchRawWithCacheFallback(info.subscribeUrl);
    // 大订阅解析放到后台 isolate，避免阻塞 UI 线程
    final nodes = await compute(_parseInIsolate, raw);
    // 拉取期间发生登出/清缓存（epoch 变化）→ 结果作废：不写内存、不写磁盘，
    // 防止旧账号数据在登出后回写"复活"
    if (epoch != _epoch) return nodes;
    _cache = nodes;
    _cacheTime = DateTime.now();
    // 串行写完磁盘缓存再返回：保证「登出删除磁盘缓存」发生在成功写入之后，
    // 杜绝删完又被异步写回旧数据的竞态
    await SubscriptionCache.instance
        .write(subscribeUrl: info.subscribeUrl, raw: raw);
    return nodes;
  }

  /// 判定错误文案是否命中「禁用/封禁」（账号不可用类，需与
  /// [AccountService] 判定口径一致；放这里避免循环依赖）
  static bool _isDisableMessage(String msg) {
    final m = msg.toLowerCase();
    return msg.contains('禁用') ||
        msg.contains('禁止') ||
        m.contains('disabled') ||
        m.contains('banned');
  }

  /// 账号受限：清空内存与磁盘缓存（磁盘删除尽力而为，不阻塞主流程）
  void _dropAllCaches() {
    // 递增代次：作废所有在途拉取 —— 受限清缓存后，任何尚未完成的旧请求
    // （旧 epoch）都不能再把数据写回内存/磁盘缓存（防"清完又复活"）
    _epoch++;
    _cache = [];
    _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(SubscriptionCache.instance.clear());
  }

  /// 拉取订阅原文；失败回退本地缓存（仅同安装且版本匹配的缓存有效）。
  /// 注意：成功的磁盘缓存写入由调用方（fetchNodes）在 epoch 校验后统一执行，
  /// 这里只负责取回原文。
  Future<String> _fetchRawWithCacheFallback(String subscribeUrl) async {
    try {
      return await ApiClient.instance.fetchText(subscribeUrl);
    } catch (e) {
      final cached = await SubscriptionCache.instance.readLatest();
      if (cached == null || cached.subscribeUrl != subscribeUrl) rethrow;
      return cached.raw;
    }
  }

  /// 面板展示性伪节点过滤（📢官网 / ⏰到期 / 📱设备 / 💬客服 等，server 为 baidu.com 占位）
  static bool _isPanelPseudoNode(ProxyNode n) {
    const markers = ['📢', '⏰', '📱', '💬', '🎯', '🚀', '♻️', '🔯', '🔮', '🛑', '🐟'];
    return markers.any((m) => n.tag.contains(m)) || n.server == 'baidu.com';
  }

  /// isolate 入口（compute 要求顶层/静态函数）
  static List<ProxyNode> _parseInIsolate(String raw) => parseClashYaml(raw);

  /// 解析 Clash YAML 中的 proxies
  static List<ProxyNode> parseClashYaml(String raw) {
    if (raw.trim().isEmpty) return [];
    dynamic doc;
    try {
      doc = loadYaml(raw);
    } catch (_) {
      return parseBase64Nodes(raw);
    }
    if (doc is! Map) {
      // loadYaml 对「base64 原文 / 明文 vmess:// 链接列表 / 其它非映射文本」
      // 不抛异常而是返回一个 String 标量 —— 以前直接 return []，最常见的
      // 两种 v2ray 订阅形态(base64 串、链接列表)会被静默丢成空列表。
      // 这里交给 base64/链接解析兜底，解析不到自然返回空。
      return parseBase64Nodes(raw);
    }
    final proxies = doc['proxies'];
    if (proxies is! List) return [];
    return proxies
        .whereType<Map>()
        .map((e) => ProxyNode.fromClashMap(Map<String, dynamic>.from(e)))
        .where((n) => n.server.isNotEmpty && n.port > 0)
        .where((n) => !_isPanelPseudoNode(n))
        .toList();
  }

  /// 兼容 base64/明文链接列表：vmess / vless / trojan / ss / socks5 /
  /// hysteria2 / tuic / anytls 等，统一转成 mihomo 认识的 Clash map。
  static List<ProxyNode> parseBase64Nodes(String raw) {
    String text = raw;
    try {
      final decoded = utf8.decode(base64.decode(base64.normalize(raw)));
      if (decoded.contains('://')) text = decoded;
    } catch (_) {}
    final nodes = <ProxyNode>[];
    for (final line in text.split('\n')) {
      final s = line.trim();
      if (s.isEmpty) continue;
      final n = _parseLink(s);
      if (n != null) nodes.add(n);
    }
    return nodes;
  }

  static ProxyNode? _parseLink(String s) {
    if (s.startsWith('vmess://')) return _parseVmess(s);
    if (s.startsWith('vless://')) return _parseVless(s);
    if (s.startsWith('trojan://')) return _parseTrojan(s);
    if (s.startsWith('ss://')) return _parseSs(s);
    if (s.startsWith('ssr://')) return _parseSsr(s);
    if (s.startsWith('socks://') || s.startsWith('socks5://')) return _parseSocks(s);
    if (s.startsWith('hysteria2://')) return _parseHysteria2(s);
    if (s.startsWith('hysteria://')) return _parseHysteria(s);
    if (s.startsWith('tuic://')) return _parseTuic(s);
    if (s.startsWith('anytls://')) return _parseAnyTls(s);
    if (s.startsWith('wireguard://')) return _parseWireguard(s);
    return null;
  }

  /// host:port → (host, port)；IPv6（[::1]:443）与非法端口返回 null
  static (String, int)? _hostPort(String s) {
    final colon = s.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(s.substring(colon + 1));
    if (port == null || port <= 0) return null;
    return (s.substring(0, colon), port);
  }

  /// query 字符串 → 已解码的键值对（URL 解码 key/value）
  static Map<String, String> _queryParams(String q) {
    final params = <String, String>{};
    for (final kv in q.split('&')) {
      if (kv.isEmpty) continue;
      final i = kv.indexOf('=');
      final k = i >= 0 ? kv.substring(0, i) : kv;
      final v = i >= 0 ? kv.substring(i + 1) : '';
      params[Uri.decodeQueryComponent(k)] = Uri.decodeQueryComponent(v);
    }
    return params;
  }

  /// 安全的 URL 解码：非法百分号编码（如裸中文 tag）回退原串，不丢节点
  static String _safeDecode(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  /// base64url 解码（SSR 各字段用 base64url、无 padding）；非 base64 原样返回
  static String _b64UrlDecode(String s) {
    if (s.isEmpty) return '';
    try {
      return utf8.decode(base64.decode(base64.normalize(s)));
    } catch (_) {
      return s;
    }
  }

  static String? _uriTag(String uri) {
    final hash = uri.indexOf('#');
    return hash >= 0 ? _safeDecode(uri.substring(hash + 1)) : null;
  }

  /// 解析 `scheme://cred@host:port?query#tag`（不含 ss/socks 的 base64 userinfo 特例）
  static ({String cred, String host, int port, Map<String, String> q})?
      _parseUserinfoUri(String scheme, String uri) {
    final without = uri.substring('$scheme://'.length);
    final hash = without.indexOf('#');
    final body = hash >= 0 ? without.substring(0, hash) : without;
    final at = body.indexOf('@');
    if (at < 0) return null;
    final cred = body.substring(0, at);
    final rest = body.substring(at + 1);
    final qm = rest.indexOf('?');
    final hostPort = qm >= 0 ? rest.substring(0, qm) : rest;
    final hp = _hostPort(hostPort);
    if (hp == null) return null;
    final q = qm >= 0 ? _queryParams(rest.substring(qm + 1)) : <String, String>{};
    return (cred: cred, host: hp.$1, port: hp.$2, q: q);
  }

  static ProxyNode? _parseVmess(String uri) {
    try {
      final b64 = uri.substring('vmess://'.length).split('#').first;
      final decoded = utf8.decode(base64.decode(base64.normalize(b64)));
      final m = jsonDecode(decoded) as Map<String, dynamic>;
      final tag = _uriTag(uri) ?? m['ps']?.toString() ?? 'vmess';
      final server = m['add']?.toString() ?? '';
      final port = int.tryParse(m['port']?.toString() ?? '') ?? 0;
      final uuid = m['id']?.toString() ?? '';
      final tls = m['tls']?.toString() == 'tls';
      final net = m['net']?.toString() ?? 'tcp';
      final sni = m['sni']?.toString();
      // 转成 mihomo 标准 vmess map：避免 vmess JSON 的 `type`(加密) 与
      // mihomo 的 `type`(协议) 冲突导致内核把节点当成 type=none 而加载失败
      final raw = <String, dynamic>{
        'name': tag,
        'type': 'vmess',
        'server': server,
        'port': port,
        'uuid': uuid,
        'alterId': int.tryParse(m['aid']?.toString() ?? '') ?? 0,
        'cipher': m['scy']?.toString() ?? 'auto',
      };
      if (tls) {
        raw['tls'] = true;
        if (sni != null && sni.isNotEmpty) raw['servername'] = sni;
        if (m['alpn']?.toString().isNotEmpty == true) {
          raw['alpn'] = m['alpn']!.toString().split(',');
        }
        if (m['fp']?.toString().isNotEmpty == true) raw['client-fingerprint'] = m['fp'];
      }
      if (net != 'tcp') raw['network'] = net;
      if (net == 'ws') {
        final wsOpts = <String, dynamic>{
          if (m['path']?.toString().isNotEmpty == true) 'path': m['path'],
        };
        if (m['host']?.toString().isNotEmpty == true) {
          wsOpts['headers'] = {'Host': m['host']};
        }
        if (wsOpts.isNotEmpty) raw['ws-opts'] = wsOpts;
      } else if (net == 'grpc') {
        raw['grpc-opts'] = {'grpc-service-name': m['path']?.toString() ?? ''};
      } else if (net == 'h2' || net == 'httpupgrade') {
        final opts = <String, dynamic>{
          if (m['path']?.toString().isNotEmpty == true) 'path': m['path'],
          if (m['host']?.toString().isNotEmpty == true) 'host': [m['host']],
        };
        raw[net == 'h2' ? 'h2-opts' : 'ws-opts'] = opts;
      }
      return ProxyNode(
        tag: tag,
        type: 'vmess',
        server: server,
        port: port,
        uuid: uuid,
        cipher: raw['cipher']?.toString(),
        tls: tls,
        sni: sni,
        network: net,
        wsPath: m['path']?.toString(),
        host: m['host']?.toString(),
        raw: raw,
      );
    } catch (_) {
      return null;
    }
  }

  static ProxyNode? _parseVless(String uri) {
    final p = _parseUserinfoUri('vless', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'vless';
    final security = p.q['security'] ?? '';
    final tls = security == 'tls' || security == 'reality' || p.q['tls'] == '1';
    final net = p.q['type'] ?? 'tcp';
    final sni = p.q['sni'] ?? p.q['peer'] ?? p.q['host'];
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'vless',
      'server': p.host,
      'port': p.port,
      'uuid': p.cred,
    };
    if (tls) {
      raw['tls'] = true;
      if (sni != null && sni.isNotEmpty) raw['servername'] = sni;
      if ((p.q['fp'] ?? '').isNotEmpty) raw['client-fingerprint'] = p.q['fp'];
    }
    if (security == 'reality') {
      final pbk = p.q['pbk'];
      final sid = p.q['sid'];
      if (pbk != null && pbk.isNotEmpty) {
        raw['reality-opts'] = {
          'public-key': pbk,
          if (sid != null && sid.isNotEmpty) 'short-id': sid,
        };
      }
    }
    if (net != 'tcp') raw['network'] = net;
    if (net == 'ws') {
      final wsOpts = <String, dynamic>{
        if ((p.q['path'] ?? '').isNotEmpty) 'path': p.q['path'],
      };
      if ((p.q['host'] ?? '').isNotEmpty) wsOpts['headers'] = {'Host': p.q['host']};
      if (wsOpts.isNotEmpty) raw['ws-opts'] = wsOpts;
    } else if (net == 'grpc') {
      raw['grpc-opts'] = {'grpc-service-name': p.q['serviceName'] ?? ''};
    }
    if ((p.q['flow'] ?? '').isNotEmpty) raw['flow'] = p.q['flow'];
    if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1') {
      raw['skip-cert-verify'] = true;
    }
    return ProxyNode(
      tag: tag,
      type: 'vless',
      server: p.host,
      port: p.port,
      uuid: p.cred,
      tls: tls,
      sni: sni,
      network: net,
      wsPath: p.q['path'],
      host: p.q['host'],
      flow: p.q['flow'],
      raw: raw,
    );
  }

  static ProxyNode? _parseTrojan(String uri) {
    final p = _parseUserinfoUri('trojan', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'trojan';
    final sni = p.q['sni'] ?? p.q['peer'];
    final net = p.q['type'] ?? 'tcp';
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'trojan',
      'server': p.host,
      'port': p.port,
      'password': p.cred,
    };
    if (sni != null && sni.isNotEmpty) raw['sni'] = sni;
    if ((p.q['alpn'] ?? '').isNotEmpty) raw['alpn'] = p.q['alpn']!.split(',');
    if ((p.q['fp'] ?? '').isNotEmpty) raw['client-fingerprint'] = p.q['fp'];
    if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1') {
      raw['skip-cert-verify'] = true;
    }
    if (net != 'tcp') raw['network'] = net;
    if (net == 'ws') {
      final wsOpts = <String, dynamic>{
        if ((p.q['path'] ?? '').isNotEmpty) 'path': p.q['path'],
      };
      if ((p.q['host'] ?? '').isNotEmpty) wsOpts['headers'] = {'Host': p.q['host']};
      if (wsOpts.isNotEmpty) raw['ws-opts'] = wsOpts;
    } else if (net == 'grpc') {
      raw['grpc-opts'] = {'grpc-service-name': p.q['serviceName'] ?? ''};
    }
    return ProxyNode(
      tag: tag,
      type: 'trojan',
      server: p.host,
      port: p.port,
      password: p.cred,
      tls: true,
      sni: sni,
      network: net,
      wsPath: p.q['path'],
      host: p.q['host'],
      raw: raw,
    );
  }

  /// 解析 Shadowsocks 链接，兼容两种主流格式：
  /// - SIP002：`ss://base64(method:password)@host:port#tag`（userinfo 是 base64）
  /// - legacy：`ss://base64(method:password@host:port)#tag`（整串 base64）
  static ProxyNode? _parseSs(String uri) {
    try {
      final withoutScheme = uri.substring('ss://'.length);
      final hash = withoutScheme.indexOf('#');
      final tag = hash >= 0 ? _safeDecode(withoutScheme.substring(hash + 1)) : 'ss';
      var body = hash >= 0 ? withoutScheme.substring(0, hash) : withoutScheme;
      // legacy：整串 base64，无明文 @ → 先整体解出 method:password@host:port
      if (!body.contains('@')) {
        body = utf8.decode(base64.decode(base64.normalize(body)));
      }
      final at = body.indexOf('@');
      if (at < 0) return null;
      final credPart = body.substring(0, at);
      final hp = _hostPort(body.substring(at + 1).split('?').first);
      if (hp == null) return null;
      // SIP002 的 userinfo 是 base64(method:password)；legacy 已是明文
      var cred = credPart;
      if (!cred.contains(':')) {
        cred = utf8.decode(base64.decode(base64.normalize(cred)));
      }
      final sep = cred.indexOf(':');
      final method = sep > 0 ? cred.substring(0, sep) : cred;
      final password = sep >= 0 ? cred.substring(sep + 1) : '';
      return ProxyNode(
        tag: tag,
        type: 'ss',
        server: hp.$1,
        port: hp.$2,
        cipher: method,
        password: password,
        raw: {
          'name': tag,
          'type': 'ss',
          'server': hp.$1,
          'port': hp.$2,
          'cipher': method,
          'password': password,
        },
      );
    } catch (_) {
      return null;
    }
  }

  /// socks5：`socks://base64(user:pass)@host:port#tag`（userinfo 可选、可 base64）
  static ProxyNode? _parseSocks(String uri) {
    try {
      final scheme = uri.startsWith('socks5://') ? 'socks5://' : 'socks://';
      final without = uri.substring(scheme.length);
      final hash = without.indexOf('#');
      final tag = hash >= 0 ? _safeDecode(without.substring(hash + 1)) : 'socks5';
      final body = hash >= 0 ? without.substring(0, hash) : without;
      final at = body.indexOf('@');
      String? username;
      String? password;
      String host;
      int port;
      if (at >= 0) {
        var cred = body.substring(0, at);
        if (cred.isNotEmpty) {
          if (!cred.contains(':')) {
            try {
              cred = utf8.decode(base64.decode(base64.normalize(cred)));
            } catch (_) {}
          }
          final sep = cred.indexOf(':');
          username = sep > 0 ? cred.substring(0, sep) : cred;
          password = sep >= 0 ? cred.substring(sep + 1) : '';
        }
        final hp = _hostPort(body.substring(at + 1).split('?').first);
        if (hp == null) return null;
        host = hp.$1;
        port = hp.$2;
      } else {
        final hp = _hostPort(body.split('?').first);
        if (hp == null) return null;
        host = hp.$1;
        port = hp.$2;
      }
      return ProxyNode(
        tag: tag,
        type: 'socks5',
        server: host,
        port: port,
        password: password,
        raw: {
          'name': tag,
          'type': 'socks5',
          'server': host,
          'port': port,
          if (username != null && username.isNotEmpty) 'username': username,
          if (password != null && password.isNotEmpty) 'password': password,
        },
      );
    } catch (_) {
      return null;
    }
  }

  static ProxyNode? _parseHysteria2(String uri) {
    final p = _parseUserinfoUri('hysteria2', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'hysteria2';
    final sni = p.q['sni'];
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'hysteria2',
      'server': p.host,
      'port': p.port,
      'password': p.cred,
      if (sni != null && sni.isNotEmpty) 'sni': sni,
      if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1')
        'skip-cert-verify': true,
    };
    return ProxyNode(
      tag: tag,
      type: 'hysteria2',
      server: p.host,
      port: p.port,
      password: p.cred,
      sni: sni,
      raw: raw,
    );
  }

  static ProxyNode? _parseTuic(String uri) {
    final p = _parseUserinfoUri('tuic', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'tuic';
    // tuic://uuid:password@host:port（: 常被百分号编码为 %3A）
    final cred = _safeDecode(p.cred);
    final sep = cred.indexOf(':');
    final uuid = sep > 0 ? cred.substring(0, sep) : cred;
    final password = sep >= 0 ? cred.substring(sep + 1) : '';
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'tuic',
      'server': p.host,
      'port': p.port,
      'uuid': uuid,
      'password': password,
      if ((p.q['sni'] ?? '').isNotEmpty) 'sni': p.q['sni'],
      if ((p.q['alpn'] ?? '').isNotEmpty) 'alpn': p.q['alpn']!.split(','),
      if ((p.q['congestion_control'] ?? p.q['congestion-controller'] ?? '').isNotEmpty)
        'congestion-controller': p.q['congestion_control'] ?? p.q['congestion-controller'],
      if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1')
        'skip-cert-verify': true,
    };
    return ProxyNode(
      tag: tag,
      type: 'tuic',
      server: p.host,
      port: p.port,
      uuid: uuid,
      password: password,
      sni: p.q['sni'],
      raw: raw,
    );
  }

  static ProxyNode? _parseAnyTls(String uri) {
    final p = _parseUserinfoUri('anytls', uri);
    if (p == null) return null;
    final tag = _uriTag(uri) ?? 'anytls';
    final raw = <String, dynamic>{
      'name': tag,
      'type': 'anytls',
      'server': p.host,
      'port': p.port,
      'password': p.cred,
      if ((p.q['sni'] ?? '').isNotEmpty) 'sni': p.q['sni'],
      if (p.q['insecure'] == '1' || p.q['allowInsecure'] == '1')
        'skip-cert-verify': true,
    };
    return ProxyNode(
      tag: tag,
      type: 'anytls',
      server: p.host,
      port: p.port,
      password: p.cred,
      sni: p.q['sni'],
      raw: raw,
    );
  }

  /// 解析 ShadowsocksR：`ssr://base64(server:port:protocol:method:obfs:password/?obfsparam=...&remarks=...)`
  /// 其中 password/obfsparam/protoparam/remarks/group 均为 base64url。
  static ProxyNode? _parseSsr(String uri) {
    try {
      final decoded = _b64UrlDecode(uri.substring('ssr://'.length));
      final qm = decoded.indexOf('?');
      final main = qm >= 0 ? decoded.substring(0, qm) : decoded;
      final qs = qm >= 0 ? decoded.substring(qm + 1) : '';
      final p = main.split(':');
      if (p.length < 6) return null;
      final server = p[0];
      final port = int.tryParse(p[1]) ?? 0;
      final protocol = p[2];
      final method = p[3];
      final obfs = p[4];
      final password = _b64UrlDecode(p[5].split('/').first);
      final params = <String, String>{};
      for (final kv in qs.split('&')) {
        if (kv.isEmpty) continue;
        final i = kv.indexOf('=');
        final k = i >= 0 ? kv.substring(0, i) : kv;
        final v = i >= 0 ? kv.substring(i + 1) : '';
        params[k] = _b64UrlDecode(v);
      }
      final tag = params['remarks']?.isNotEmpty == true ? params['remarks']! : 'ssr';
      final raw = <String, dynamic>{
        'name': tag,
        'type': 'ssr',
        'server': server,
        'port': port,
        'cipher': method,
        'password': password,
        'protocol': protocol,
        'obfs': obfs,
        if (params['obfsparam']?.isNotEmpty == true) 'obfs-param': params['obfsparam'],
        if (params['protoparam']?.isNotEmpty == true)
          'protocol-param': params['protoparam'],
      };
      return ProxyNode(
        tag: tag,
        type: 'ssr',
        server: server,
        port: port,
        cipher: method,
        password: password,
        raw: raw,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 Hysteria v1：`hysteria://host:port/?auth=...&peer=...&obfs=xplus#tag`
  /// （v1 无 userinfo，密码在 auth 参数里，与 hysteria2 不同）
  static ProxyNode? _parseHysteria(String uri) {
    try {
      final without = uri.substring('hysteria://'.length);
      final hash = without.indexOf('#');
      final tag = hash >= 0 ? _safeDecode(without.substring(hash + 1)) : 'hysteria';
      final body = hash >= 0 ? without.substring(0, hash) : without;
      final qm = body.indexOf('?');
      final hostPort = qm >= 0 ? body.substring(0, qm) : body;
      final hp = _hostPort(hostPort);
      if (hp == null) return null;
      final q = qm >= 0 ? _queryParams(body.substring(qm + 1)) : <String, String>{};
      final auth = q['auth'] ?? '';
      final sni = q['peer'] ?? q['sni'];
      final raw = <String, dynamic>{
        'name': tag,
        'type': 'hysteria',
        'server': hp.$1,
        'port': hp.$2,
        if (auth.isNotEmpty) 'auth_str': auth,
        if (sni != null && sni.isNotEmpty) 'sni': sni,
        if ((q['upmbps'] ?? '').isNotEmpty) 'up': int.tryParse(q['upmbps']!) ?? 0,
        if ((q['downmbps'] ?? '').isNotEmpty)
          'down': int.tryParse(q['downmbps']!) ?? 0,
        if ((q['alpn'] ?? '').isNotEmpty) 'alpn': q['alpn']!.split(','),
        if ((q['obfs'] ?? '').isNotEmpty) 'obfs': q['obfs'],
        if ((q['obfsParam'] ?? q['obfs-param'] ?? '').isNotEmpty)
          'obfs-param': q['obfsParam'] ?? q['obfs-param'],
        if (q['insecure'] == '1') 'skip-cert-verify': true,
      };
      return ProxyNode(
        tag: tag,
        type: 'hysteria',
        server: hp.$1,
        port: hp.$2,
        password: auth,
        sni: sni,
        raw: raw,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 WireGuard：`wireguard://base64(ini_conf)#tag`
  /// （链接里直接是 base64 的 .conf 内容，解析成 mihomo wireguard map）
  static ProxyNode? _parseWireguard(String uri) {
    try {
      final conf = _b64UrlDecode(uri.substring('wireguard://'.length).split('#').first);
      final tag = _uriTag(uri) ?? 'wireguard';
      final kv = <String, String>{};
      for (final line in conf.split('\n')) {
        final l = line.trim();
        if (l.isEmpty || l.startsWith('[')) continue;
        final i = l.indexOf('=');
        if (i < 0) continue;
        kv[l.substring(0, i).trim().toLowerCase()] = l.substring(i + 1).trim();
      }
      final endpoint = kv['endpoint'];
      if (endpoint == null) return null;
      final hp = _hostPort(endpoint);
      if (hp == null) return null;
      final raw = <String, dynamic>{
        'name': tag,
        'type': 'wireguard',
        'server': hp.$1,
        'port': hp.$2,
        'udp': true,
        if (kv['privatekey'] != null) 'private-key': kv['privatekey'],
        if (kv['publickey'] != null) 'public-key': kv['publickey'],
        if (kv['address'] != null) 'ip': kv['address']!.split(',').first.trim(),
        if (kv['presharedkey'] != null) 'preshared-key': kv['presharedkey'],
      };
      return ProxyNode(
        tag: tag,
        type: 'wireguard',
        server: hp.$1,
        port: hp.$2,
        raw: raw,
      );
    } catch (_) {
      return null;
    }
  }
}
