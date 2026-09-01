import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/proxy/proxy_core.dart';
import '../../core/services/subscription_service.dart';
import '../../theme/app_theme.dart';

/// 节点列表（设计稿 03）：自动选优条 + 分组 + 延迟徽标 + 真实测速
class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  bool _autoBest = true;
  bool _testing = false;
  String _query = '';

  Future<void> _load({bool force = false}) async {
    final conn = context.read<ConnectionController>();
    try {
      final nodes = await SubscriptionService.instance.fetchNodes(force: force);
      await conn.loadNodes(nodes);
      if (mounted && nodes.isEmpty) _toast('订阅中没有可用节点');
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  Future<void> _runSpeedTest() async {
    final conn = context.read<ConnectionController>();
    if (conn.nodes.isEmpty) {
      _toast('暂无节点');
      return;
    }
    setState(() => _testing = true);
    try {
      final tested = await SpeedTester.instance.testAll(conn.nodes);
      await conn.loadNodes(tested);
      if (mounted) {
        _toast('测速完成，已按延迟排序');
        if (_autoBest) {
          final best = SpeedTester.selectBest(tested);
          if (best != null) await conn.switchNode(best);
        }
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final filtered = conn.nodes
        .where((n) => n.tag.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    final groups = <String, List<dynamic>>{};
    for (final n in filtered) {
      final key = n.countryCode ?? 'XX';
      groups.putIfAbsent(key, () => []).add(n);
    }
    final sortedCodes = groups.keys.toList()
      ..sort((a, b) => _regionName(a).compareTo(_regionName(b)));

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 4),
              child: Row(
                children: [
                  const Text('节点列表', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _load(force: true),
                    child: const Text('🔄 刷新订阅', style: TextStyle(fontSize: 12, color: MFColors.brandLight, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      decoration: BoxDecoration(
                          color: MFColors.card, borderRadius: BorderRadius.circular(13),
                          border: Border.all(color: MFColors.line2)),
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        style: const TextStyle(color: MFColors.txt, fontSize: 13.5),
                        decoration: const InputDecoration(
                          hintText: '搜索节点 / 地区 / 协议',
                          hintStyle: TextStyle(fontSize: 13, color: MFColors.txt3),
                          border: InputBorder.none,
                          prefixIcon: Icon(Icons.search, size: 17, color: MFColors.txt3),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _testing ? null : _runSpeedTest,
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(13)),
                      alignment: Alignment.center,
                      child: Text(_testing ? '测速中…' : '⚡ 测速',
                          style: const TextStyle(fontSize: 12.5, color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
            // 自动选优条
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  gradient: const LinearGradient(colors: [Color(0x24455FE9), Color(0x08455FE9)]),
                  border: Border.all(color: MFColors.brand.withValues(alpha: .3)),
                ),
                child: Row(
                  children: [
                    const Text('✨', style: TextStyle(fontSize: 14)),
                    const SizedBox(width: 7),
                    const Expanded(
                      child: Text('自动选择最优节点', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _autoBest = !_autoBest),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: _autoBest ? MFColors.green.withValues(alpha: .1) : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _autoBest ? MFColors.green.withValues(alpha: .3) : MFColors.line2),
                        ),
                        child: Text(_autoBest ? '已开启' : '已关闭',
                            style: TextStyle(fontSize: 9.5,
                                color: _autoBest ? MFColors.green : MFColors.txt3,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _runSpeedTest,
                      child: Container(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(9)),
                        alignment: Alignment.center,
                        child: const Text('立即选优', style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 节点列表
            Expanded(
              child: conn.nodes.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('暂无节点', style: TextStyle(fontSize: 14, color: MFColors.txt3)),
                          const SizedBox(height: 10),
                          GestureDetector(
                            onTap: () => _load(force: true),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(12)),
                              child: const Text('刷新订阅', style: TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 12),
                      children: [
                        for (final code in sortedCodes) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 6, 24, 7),
                            child: Row(
                              children: [
                                Text(_flagOf(code), style: const TextStyle(fontSize: 13)),
                                const SizedBox(width: 7),
                                Text(_regionName(code),
                                    style: const TextStyle(fontSize: 12, color: MFColors.txt3, fontWeight: FontWeight.w700, letterSpacing: 1)),
                                const Spacer(),
                                Text('${groups[code]!.length} 个节点',
                                    style: const TextStyle(fontSize: 11, color: MFColors.txt3, fontFamily: kNumFont)),
                              ],
                            ),
                          ),
                          for (final n in groups[code]!) _buildNodeRow(conn, n),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeRow(ConnectionController conn, dynamic n) {
    final isCurrent = conn.current?.tag == n.tag;
    final latencyColor = !n.online
        ? MFColors.red
        : (n.latencyMs < 100 ? MFColors.green : (n.latencyMs < 300 ? MFColors.amber : MFColors.red));
    return GestureDetector(
      onTap: () async {
        await conn.switchNode(n);
        if (mounted) _toast('已切换到 ${n.tag}');
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(22, 0, 22, 8),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
          color: isCurrent ? MFColors.brand.withValues(alpha: .09) : MFColors.card,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: isCurrent ? MFColors.brand.withValues(alpha: .6) : MFColors.line),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: const Color(0xFF1B2233), borderRadius: BorderRadius.circular(11)),
              alignment: Alignment.center,
              child: Text(n.flag, style: const TextStyle(fontSize: 17)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(n.tag, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text('${n.type} · ${n.port}',
                      style: const TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont)),
                  if (isCurrent) ...[
                    const SizedBox(height: 2),
                    const Text('✨ 已选中', style: TextStyle(fontSize: 9.5, color: MFColors.brandLight, fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: latencyColor.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: latencyColor.withValues(alpha: .25)),
              ),
              child: Text(n.online ? '${n.latencyMs} ms' : '— ms',
                  style: TextStyle(fontSize: 11.5, color: latencyColor, fontFamily: kNumFont, fontWeight: FontWeight.w600)),
            ),
            if (isCurrent) ...[
              const SizedBox(width: 8),
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(gradient: MFColors.brandGradient, shape: BoxShape.circle),
                child: const Icon(Icons.check, size: 11, color: Colors.white),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _flagOf(String code) {
    const flags = {
      'HK': '🇭🇰', 'TW': '🇹🇼', 'JP': '🇯🇵', 'SG': '🇸🇬', 'KR': '🇰🇷',
      'US': '🇺🇸', 'GB': '🇬🇧', 'DE': '🇩🇪', 'FR': '🇫🇷', 'AU': '🇦🇺',
      'CA': '🇨🇦', 'RU': '🇷🇺', 'IN': '🇮🇳', 'TH': '🇹🇭', 'VN': '🇻🇳',
      'NL': '🇳🇱', 'SE': '🇸🇪', 'AE': '🇦🇪',
    };
    return flags[code] ?? '🌐';
  }

  static String _regionName(String code) {
    const names = {
      'HK': '香港', 'TW': '台湾', 'JP': '日本', 'SG': '新加坡', 'KR': '韩国',
      'US': '美国', 'GB': '英国', 'DE': '德国', 'FR': '法国', 'AU': '澳大利亚',
      'CA': '加拿大', 'RU': '俄罗斯', 'IN': '印度', 'TH': '泰国', 'VN': '越南',
      'NL': '荷兰', 'SE': '瑞典', 'AE': '阿联酋', 'XX': '其他',
    };
    return names[code] ?? '其他';
  }
}
