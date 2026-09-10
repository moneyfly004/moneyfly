import 'dart:io';

import '../models/models.dart';

/// 本地测速：并发 TCP 连接计时（3 次取中位数）
/// 纯 Dart（仅 dart:io + models），可独立运行与单元测试
class SpeedTester {
  SpeedTester({this.connectTimeout = const Duration(seconds: 5)});
  static final SpeedTester instance = SpeedTester();

  /// 连接超时（可配置：正常 5s，大批量验证可缩短）
  final Duration connectTimeout;
  static const _probeCount = 3;
  static const _maxConcurrent = 12;

  /// 测单个节点延迟（ms），失败返回 -1。
  /// UDP-only 协议（hysteria/hysteria2/tuic/wireguard）无 TCP 监听，
  /// 裸 TCP 探测必然失败，直接返回 -1（调用方不应据此判离线，见 testAll）。
  Future<int> testOne(ProxyNode node) async {
    if (node.isUdpOnly) return -1;
    final samples = <int>[];
    for (var i = 0; i < _probeCount; i++) {
      final sw = Stopwatch()..start();
      Socket? socket;
      try {
        socket = await Socket.connect(node.server, node.port, timeout: connectTimeout);
        sw.stop();
        samples.add(sw.elapsedMilliseconds);
      } catch (_) {
        return -1;
      } finally {
        socket?.destroy();
      }
    }
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  /// 并发测速全部节点（自动限流），返回带延迟的新列表。
  /// 测速在**副本**上进行，绝不把结果写进传入列表的元素 —— 调用方只在
  /// 需要时整体替换引用（断开/切换瞬间的测速结果不会污染 UI 当前列表）。
  /// [onEach] 每测完一个节点即回调 (tag, 延迟ms, 是否在线)，供调用方实时回填
  /// UI（边测边刷、实时重排），不必等整批完成。
  Future<List<ProxyNode>> testAll(List<ProxyNode> nodes,
      {void Function(int done, int total)? onProgress,
      void Function(String tag, int latencyMs, bool online)? onEach}) async {
    final result = [for (final n in nodes) n.clone()];
    final queue = List<int>.generate(result.length, (i) => i);
    var done = 0;

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final idx = queue.removeLast();
        final n = result[idx];
        final udp = n.isUdpOnly;
        final ms = udp ? -1 : await testOne(n);
        n.latencyMs = ms;
        // UDP 协议裸 TCP 测不了，保持「在线但延迟未知」，等连接后内核实测
        n.online = udp ? true : ms >= 0;
        done++;
        onProgress?.call(done, result.length);
        onEach?.call(n.tag, ms, n.online);
      }
    }

    final count = result.isEmpty
        ? 1
        : (result.length < _maxConcurrent ? result.length : _maxConcurrent);
    await Future.wait(List.generate(count, (_) => worker()));
    return result;
  }

  /// 选优：延迟最低 + 负载惩罚（raw['load'] 每 10% ≈ +1ms）
  static ProxyNode? selectBest(List<ProxyNode> nodes) {
    final online = nodes.where((n) => n.online && n.latencyMs >= 0).toList();
    if (online.isEmpty) return null;
    online.sort((a, b) {
      final la = a.latencyMs + _loadPenalty(a);
      final lb = b.latencyMs + _loadPenalty(b);
      return la.compareTo(lb);
    });
    return online.first;
  }

  static int _loadPenalty(ProxyNode n) {
    final load = n.raw['load'] is num ? (n.raw['load'] as num).toDouble() : 0;
    return (load * 10).round();
  }

  /// 按国家聚合出该国最低延迟
  static Map<String, int> bestLatencyByCountry(List<ProxyNode> nodes) {
    final map = <String, int>{};
    for (final n in nodes) {
      if (!n.online || n.latencyMs < 0) continue;
      final code = n.countryCode ?? 'XX';
      final cur = map[code];
      if (cur == null || n.latencyMs < cur) map[code] = n.latencyMs;
    }
    return map;
  }
}
