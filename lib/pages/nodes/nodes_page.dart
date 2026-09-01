import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/proxy/proxy_core.dart';
import '../../core/services/speed_tester.dart';
import '../../core/services/subscription_service.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/country_flag.dart';

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
  Timer? _debounce; // 搜索防抖

  Future<void> _load({bool force = false}) async {
    final conn = context.read<ConnectionController>();
    try {
      final nodes = await SubscriptionService.instance.fetchNodes(force: force);
      await conn.loadNodes(nodes);
      if (mounted && nodes.isEmpty) _toast(AppStrings.t('no_nodes_hint'));
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  Future<void> _runSpeedTest() async {
    final conn = context.read<ConnectionController>();
    if (conn.nodes.isEmpty) {
      _toast(AppStrings.t('no_nodes'));
      return;
    }
    setState(() => _testing = true);
    try {
      final tested = await SpeedTester.instance.testAll(conn.nodes);
      await conn.loadNodes(tested);
      if (mounted) {
        _toast(AppStrings.t('speed_done'));
        if (_autoBest) {
          final best = SpeedTester.selectBest(tested);
          if (best != null) await conn.switchNode(best);
        }
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
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
      ..sort((a, b) => regionName(a).compareTo(regionName(b)));

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 4),
              child: Row(
                children: [
                  Text(AppStrings.t('nodes_title'), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _load(force: true),
                    child: Text('🔄 ${AppStrings.t('refresh_sub')}', style: const TextStyle(fontSize: 12, color: MFColors.brandLight, fontWeight: FontWeight.w600)),
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
                        onChanged: (v) {
                          // 300ms 防抖：输入时不做全量过滤，滚动更流畅
                          _debounce?.cancel();
                          _debounce = Timer(const Duration(milliseconds: 300), () {
                            if (mounted) setState(() => _query = v.trim());
                          });
                        },
                        style:  TextStyle(color: MFColors.txt, fontSize: 13.5),
                        decoration: InputDecoration(
                          hintText: AppStrings.t('search_hint'),
                          hintStyle:  TextStyle(fontSize: 13, color: MFColors.txt3),
                          border: InputBorder.none,
                          prefixIcon:  Icon(Icons.search, size: 17, color: MFColors.txt3),
                          suffixIcon: _query.isEmpty
                              ? null
                              : GestureDetector(
                                  onTap: () {
                                    _debounce?.cancel();
                                    setState(() => _query = '');
                                  },
                                  child:  Icon(Icons.close, size: 16, color: MFColors.txt3),
                                ),
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
                      child: Text(_testing ? AppStrings.t('speed_testing') : '⚡ ${AppStrings.t('speed_test')}',
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
                    Expanded(
                      child: Text(AppStrings.t('auto_best'), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
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
                        child: Text(_autoBest ? AppStrings.t('auto_test_on') : AppStrings.t('auto_test_off'),
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
                        child: Text(AppStrings.t('pick_best'), style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
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
                           Text(AppStrings.t('no_nodes'), style: TextStyle(fontSize: 14, color: MFColors.txt3)),
                          const SizedBox(height: 10),
                          GestureDetector(
                            onTap: () => _load(force: true),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(12)),
                              child: Text(AppStrings.t('refresh_sub'), style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
                    )
                  : _NodeListView(
                      conn: conn,
                      groups: groups,
                      sortedCodes: sortedCodes,
                      buildNodeRow: _buildNodeRow,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeRow(ConnectionController conn, dynamic n) {
    final isCurrent = conn.current?.tag == n.tag;
    // 未测速（latencyMs < 0）显示中性色，避免误导为“极低延迟”
    final untested = n.online && n.latencyMs < 0;
    final latencyColor = untested
        ? MFColors.txt3
        : !n.online
            ? MFColors.red
            : (n.latencyMs < 100 ? MFColors.green : (n.latencyMs < 300 ? MFColors.amber : MFColors.red));
    return GestureDetector(
      onTap: () async {
        await conn.switchNode(n);
        if (mounted) _toast(AppStrings.t('switched_to', {'name': n.tag}));
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
              child: CountryFlag(n.countryCode, size: 17),
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
                      style:  TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont)),
                  if (isCurrent) ...[
                    const SizedBox(height: 2),
                    Text('✨ ${AppStrings.t('selected')}', style: const TextStyle(fontSize: 9.5, color: MFColors.brandLight, fontWeight: FontWeight.w600)),
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
              child: Text(n.online && n.latencyMs >= 0 ? '${n.latencyMs} ms' : '— ms',
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
}


/// 节点懒加载列表：分组头/节点行拍平为索引，只构建视口内可见项（680+ 节点也流畅）
class _NodeListView extends StatelessWidget {
  const _NodeListView({
    required this.conn,
    required this.groups,
    required this.sortedCodes,
    required this.buildNodeRow,
  });

  final ConnectionController conn;
  final Map<String, List<dynamic>> groups;
  final List<String> sortedCodes;
  final Widget Function(ConnectionController, dynamic) buildNodeRow;

  @override
  Widget build(BuildContext context) {
    // 拍平：header 用负索引标记，节点行用实际对象
    final entries = <dynamic>[];
    for (final code in sortedCodes) {
      entries.add('__header__$code');
      entries.addAll(groups[code]!);
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        if (e is String && e.startsWith('__header__')) {
          final code = e.substring('__header__'.length);
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 7),
            child: Row(
              children: [
                Text(regionFlag(code), style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 7),
                Text(regionName(code),
                    style:  TextStyle(fontSize: 12, color: MFColors.txt3, fontWeight: FontWeight.w700, letterSpacing: 1)),
                const Spacer(),
                Text('${groups[code]!.length} ${AppStrings.t('nodes_count')}',
                    style:  TextStyle(fontSize: 11, color: MFColors.txt3, fontFamily: kNumFont)),
              ],
            ),
          );
        }
        return buildNodeRow(conn, e);
      },
    );
  }
}

/// 地区旗标（顶层函数，供懒加载列表与分组排序共用）
String regionFlag(String code) {
  const flags = {
    'HK': '🇭🇰', 'TW': '🇹🇼', 'JP': '🇯🇵', 'SG': '🇸🇬', 'KR': '🇰🇷',
    'US': '🇺🇸', 'GB': '🇬🇧', 'DE': '🇩🇪', 'FR': '🇫🇷', 'AU': '🇦🇺',
    'CA': '🇨🇦', 'RU': '🇷🇺', 'IN': '🇮🇳', 'TH': '🇹🇭', 'VN': '🇻🇳',
    'NL': '🇳🇱', 'SE': '🇸🇪', 'AE': '🇦🇪',
  };
  return flags[code] ?? '🌐';
}

/// 地区名（顶层函数）
String regionName(String code) {
  const names = {
    'HK': '香港', 'TW': '台湾', 'JP': '日本', 'SG': '新加坡', 'KR': '韩国',
    'US': '美国', 'GB': '英国', 'DE': '德国', 'FR': '法国', 'AU': '澳大利亚',
    'CA': '加拿大', 'RU': '俄罗斯', 'IN': '印度', 'TH': '泰国', 'VN': '越南',
    'NL': '荷兰', 'SE': '瑞典', 'AE': '阿联酋', 'XX': '其他',
  };
  return names[code] ?? '其他';
}
