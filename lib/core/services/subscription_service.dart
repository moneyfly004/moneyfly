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
    if (doc is! Map) return [];
    final proxies = doc['proxies'];
    if (proxies is! List) return [];
    return proxies
        .whereType<Map>()
        .map((e) => ProxyNode.fromClashMap(Map<String, dynamic>.from(e)))
        .where((n) => n.server.isNotEmpty && n.port > 0)
        .where((n) => !_isPanelPseudoNode(n))
        .toList();
  }

  /// 兼容 v2ray base64 链接列表（vmess:// vless:// trojan:// ss://）
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
      if (s.startsWith('vmess://')) {
        final n = _parseVmess(s);
        if (n != null) nodes.add(n);
      } else if (s.startsWith('vless://')) {
        final n = _parseShareLink('vless', s);
        if (n != null) nodes.add(n);
      } else if (s.startsWith('trojan://')) {
        final n = _parseShareLink('trojan', s);
        if (n != null) nodes.add(n);
      } else if (s.startsWith('ss://')) {
        final n = _parseShareLink('ss', s);
        if (n != null) nodes.add(n);
      }
    }
    return nodes;
  }

  static ProxyNode? _parseVmess(String uri) {
    try {
      final b64 = uri.substring('vmess://'.length).split('#').first;
      final decoded = utf8.decode(base64.decode(base64.normalize(b64)));
      final m = jsonDecode(decoded) as Map<String, dynamic>;
      return ProxyNode(
        tag: uri.contains('#') ? Uri.decodeComponent(uri.split('#').last) : (m['ps']?.toString() ?? 'vmess'),
        type: 'vmess',
        server: m['add']?.toString() ?? '',
        port: (m['port'] as num?)?.toInt() ?? 0,
        uuid: m['id']?.toString(),
        cipher: m['type']?.toString() == 'none' ? 'auto' : (m['scy']?.toString() ?? 'auto'),
        tls: m['tls']?.toString() == 'tls',
        sni: m['sni']?.toString(),
        network: m['net']?.toString(),
        wsPath: m['path']?.toString(),
        host: m['host']?.toString(),
        raw: m,
      );
    } catch (_) {
      return null;
    }
  }

  static ProxyNode? _parseShareLink(String type, String uri) {
    try {
      final withoutScheme = uri.substring('$type://'.length);
      final parts = withoutScheme.split('#');
      final tag = parts.length > 1 ? Uri.decodeComponent(parts.last) : type;
      final beforeHash = parts.first;
      // trojan://password@host:port?params 或 ss://base64@host:port
      final at = beforeHash.indexOf('@');
      final cred = at >= 0 ? beforeHash.substring(0, at) : '';
      final rest = at >= 0 ? beforeHash.substring(at + 1) : beforeHash;
      final hostPort = rest.split('?').first;
      final colon = hostPort.lastIndexOf(':');
      final host = colon > 0 ? hostPort.substring(0, colon) : hostPort;
      final port = int.tryParse(hostPort.substring(colon + 1)) ?? 0;
      final query = rest.contains('?') ? rest.substring(rest.indexOf('?') + 1) : '';
      Map<String, dynamic> params = {};
      for (final kv in query.split('&')) {
        if (kv.contains('=')) params[kv.split('=').first] = Uri.decodeComponent(kv.split('=').last);
      }
      final password = cred.contains(':') ? Uri.decodeComponent(cred.split(':').last) : Uri.decodeComponent(cred);
      return ProxyNode(
        tag: tag,
        type: type,
        server: host,
        port: port,
        password: password,
        tls: type == 'trojan' || params['security'] == 'tls' || params['tls'] == '1',
        sni: params['sni']?.toString() ?? params['peer']?.toString(),
        network: params['type']?.toString(),
        wsPath: params['path']?.toString(),
        host: params['host']?.toString(),
        flow: params['flow']?.toString(),
        raw: params,
      );
    } catch (_) {
      return null;
    }
  }
}
