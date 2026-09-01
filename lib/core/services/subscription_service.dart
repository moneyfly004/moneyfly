import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';

import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 订阅服务：拉取订阅信息 → 获取 Clash YAML → 解析节点列表
class SubscriptionService {
  SubscriptionService._();
  static final SubscriptionService instance = SubscriptionService._();

  List<ProxyNode> _cache = [];
  DateTime _cacheTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const _cacheTtl = Duration(minutes: 30);

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
        status: '',
      );
    }
    return SubscriptionInfo.fromJson(Map<String, dynamic>.from(data));
  }

  /// 获取并解析节点列表（带 30 分钟缓存，force 强制刷新）
  Future<List<ProxyNode>> fetchNodes({bool force = false}) async {
    if (!force && _cache.isNotEmpty && DateTime.now().difference(_cacheTime) < _cacheTtl) {
      return List.of(_cache);
    }
    final info = await fetchInfo();
    if (info.subscribeUrl.isEmpty) return [];
    final raw = await ApiClient.instance.fetchText(info.subscribeUrl);
    // 大订阅解析放到后台 isolate，避免阻塞 UI 线程
    final nodes = await compute(_parseInIsolate, raw);
    _cache = nodes;
    _cacheTime = DateTime.now();
    return nodes;
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
