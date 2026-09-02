import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/services/speed_tester.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/subscription_service.dart';
import '../../core/api/api_client.dart';
import '../../l10n/app_strings.dart';
import '../../core/services/geo_lookup.dart';
import '../../main.dart';
import '../../theme/app_theme.dart';
import '../../widgets/country_flag.dart';
import '../settings/settings_page.dart';

/// 首页 · 连接页（设计稿 02）
/// 电源按钮 / 智能·全局模式 / 自动测速选优卡 / 快速切换国家 / 实时速率
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _loadingNodes = false;

  /// 连接状态下的呼吸动画（仅连接时运行，断开即停 → 省电 + 流畅）
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
    lowerBound: .35,
    upperBound: 1,
  );

  @override
  void initState() {
    super.initState();
    _ensureNodes();
    // 连接状态变化时启停呼吸动画
    ConnectionController.instance.addListener(_onConnChanged);
    // 回前台自动刷新订阅（保活页面避免数据过期）
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    ConnectionController.instance.removeListener(_onConnChanged);
    WidgetsBinding.instance.removeObserver(this);
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _ensureNodes();
    }
  }

  void _onConnChanged() {
    if (!mounted) return;
    final s = ConnectionController.instance.status;
    if (s == ConnStatus.connected && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (s != ConnStatus.connected && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  Future<void> _ensureNodes({bool force = false}) async {
    final conn = context.read<ConnectionController>();
    if (conn.nodes.isNotEmpty && !force) return;
    if (!mounted) return;
    setState(() => _loadingNodes = true);
    try {
      final nodes = await SubscriptionService.instance.fetchNodes(force: force);
      await conn.loadNodes(nodes);
      // 设置「启动时自动连接」→ 订阅加载完成后自动连接（每次启动仅一次）
      unawaited(conn.autoConnectIfEnabled());
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loadingNodes = false);
    }
  }

  Future<void> _toggleConnect(ConnectionController conn) async {
    // 触感反馈（Android）
    unawaited(HapticFeedback.mediumImpact());
    if (conn.status == ConnStatus.connected) {
      await conn.disconnect();
    } else if (conn.status == ConnStatus.testing ||
        conn.status == ConnStatus.connecting ||
        conn.status == ConnStatus.reconnecting) {
      // 连接/测速进行中再点一次 = 取消本次连接
      await conn.disconnect();
      _toast('已取消连接');
    } else if (conn.nodes.isEmpty) {
      _toast(AppStrings.t('no_nodes'));
    } else {
      // 连接前：VPN 授权 + 通知 + 电池优化豁免（最高权限，防断连/防杀后台）
      final ok = await PermissionService.instance.ensureAllForConnect();
      if (!ok) {
        _toast(AppStrings.t('vpn_permission_needed'));
        return;
      }
      await conn.connect();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final connected = conn.status == ConnStatus.connected;
    final busy = conn.status == ConnStatus.testing || conn.status == ConnStatus.connecting;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _ensureNodes(force: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 22),
            children: [
              _buildHeader(),
              const SizedBox(height: 6),
              if (conn.nodes.isEmpty) ...[
                _buildNoSubscriptionBanner(),
                const SizedBox(height: 12),
              ],
              _buildConnectCard(conn, connected, busy),
              const SizedBox(height: 12),
              _buildModeSwitch(conn),
              const SizedBox(height: 12),
              _buildAutoTestCard(conn),
              const SizedBox(height: 12),
              _buildRegionGrid(conn),
              const SizedBox(height: 12),
              _buildStats(conn),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  /// 未开通/订阅过期引导条 → 一键跳充值
  Widget _buildNoSubscriptionBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0x33FFB020), Color(0x0DFFB020)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MFColors.amber.withValues(alpha: .4)),
      ),
      child: Row(
        children: [
          const Text('🛒', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 9),
           Expanded(
            child: Text(AppStrings.t('no_subscription'),
                style: TextStyle(fontSize: 12, color: MFColors.txt)),
          ),
          GestureDetector(
            onTap: () => mainTabIndex.value = 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(10)),
              child: Text(AppStrings.t('go_purchase'), style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(11)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Image.asset('assets/moneyfly-logo.png', width: 36, height: 36),
            ),
          ),
          const SizedBox(width: 10),
           Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MoneyFly', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
              Text(AppStrings.t('home_ready'), style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
            ],
          ),
          const Spacer(),
          IconButton(
            icon:  Icon(Icons.refresh, size: 20, color: MFColors.txt2),
            tooltip: AppStrings.t('refresh_sub'),
            onPressed: _loadingNodes ? null : () => _ensureNodes(force: true),
          ),
          IconButton(
            icon:  Icon(Icons.settings_outlined, size: 20, color: MFColors.txt2),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectCard(ConnectionController conn, bool connected, bool busy) {
    final node = conn.current;
    final statusColor = busy
        ? MFColors.amber
        : (connected ? MFColors.green : MFColors.txt3);
    final statusLabel = switch (conn.status) {
      ConnStatus.testing => AppStrings.t('testing'),
      ConnStatus.connecting => AppStrings.t('connecting'),
      ConnStatus.reconnecting => AppStrings.t('reconnecting'),
      ConnStatus.connected =>
        conn.speedTesting ? AppStrings.t('connected_speed_testing') : AppStrings.t('connected'),
      ConnStatus.error => AppStrings.t('error'),
      _ => AppStrings.t('disconnected'),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF151B2B), Color(0xFF10141F)]),
        border: Border.all(
            color: connected ? MFColors.green.withValues(alpha: .4) : MFColors.line2),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: () => _toggleConnect(conn),
            // RepaintBoundary：呼吸动画只重绘按钮区域，不影响整页
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) {
                  final glow = connected ? _pulse.value : 1.0;
                  return Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: connected
                              ? MFColors.green.withValues(alpha: .45 * glow)
                              : MFColors.brand.withValues(alpha: .25),
                          blurRadius: 34,
                        ),
                      ],
                    ),
                    child: child,
                  );
                },
                child: Container(
                  margin: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: connected
                        ? const RadialGradient(colors: [Color(0xFF1E3B3A), Color(0xFF0E1716)], stops: [0, .75])
                        : const RadialGradient(colors: [Color(0xFF1B2233), Color(0xFF0E121B)], stops: [0, .75]),
                    border: Border.all(
                        color: connected ? MFColors.green.withValues(alpha: .5) : MFColors.line2,
                        width: 1.2),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(statusLabel,
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 2, color: statusColor)),
                      const SizedBox(height: 3),
                      Text(
                        switch (conn.status) {
                          ConnStatus.testing => 'TESTING',
                          ConnStatus.connecting => 'CONNECTING',
                          ConnStatus.connected => 'CONNECTED',
                          ConnStatus.error => 'ERROR',
                          _ => 'OFFLINE',
                        },
                        style: TextStyle(
                            fontSize: 9, fontFamily: kNumFont, fontWeight: FontWeight.w600,
                            color: connected ? const Color(0xFFD8FFEF) : MFColors.txt3),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (node != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CountryFlag(node.countryCode, size: 17),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(node.tag,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                if (node.latencyMs >= 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                    decoration: BoxDecoration(
                      color: MFColors.green.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: MFColors.green.withValues(alpha: .25)),
                    ),
                    child: Text('${node.latencyMs} ms',
                        style: const TextStyle(fontSize: 12, color: MFColors.green, fontFamily: kNumFont, fontWeight: FontWeight.w600)),
                  ),
                ],
              ],
            )
          else
             Text(AppStrings.t('no_nodes'),
                style: TextStyle(fontSize: 13, color: MFColors.txt3)),
          // 真实出口：连接后通过隧道 IP 定位实测（非节点名猜测）
          if (connected && conn.realCountry != null) ...[
            const SizedBox(height: 7),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CountryFlag(conn.realCountry, size: 13, rounded: true),
                const SizedBox(width: 5),
                Text('真实出口 · ${GeoLookupService.countryName(conn.realCountry)}',
                    style: const TextStyle(fontSize: 11, color: MFColors.green)),
              ],
            ),
          ],
          if (conn.error != null) ...[
            const SizedBox(height: 8),
            Text(conn.error!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: MFColors.red)),
          ],
        ],
      ),
    );
  }

  Widget _buildModeSwitch(ConnectionController conn) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
          color: MFColors.card, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: MFColors.line)),
      child: Row(
        children: [
          _ModeOption(
            label: AppStrings.t('smart_mode'),
            icon: Icons.gps_fixed,
            selected: conn.smartMode,
            onTap: () => conn.toggleMode(true),
          ),
          _ModeOption(
            label: AppStrings.t('global_mode'),
            icon: Icons.travel_explore,
            selected: !conn.smartMode,
            onTap: () => conn.toggleMode(false),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoTestCard(ConnectionController conn) {
    final best = SpeedTester.selectBest(conn.nodes);
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
            colors: [Color(0x29455FE9), Color(0x0A455FE9)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        border: Border.all(color: MFColors.brand.withValues(alpha: .35)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.bolt, size: 15, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Text(AppStrings.t('auto_test_title'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const Spacer(),
              GestureDetector(
                onTap: () => conn.setAutoTest(!conn.autoTest),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: conn.autoTest ? MFColors.green.withValues(alpha: .1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: conn.autoTest ? MFColors.green.withValues(alpha: .3) : MFColors.line2),
                  ),
                  child: Text(conn.autoTest ? '● ${AppStrings.t('auto_test_on')}' : '○ ${AppStrings.t('auto_test_off')}',
                      style: TextStyle(fontSize: 10,
                          color: conn.autoTest ? MFColors.green : MFColors.txt3,
                          fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .35),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: MFColors.line)),
                  child: Row(
                    children: [
                      CountryFlag(best?.countryCode, size: 15),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(best?.tag ?? AppStrings.t('no_nodes'),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ),
                      if (best != null && best.latencyMs >= 0) ...[
                        Text('${best.latencyMs} ms',
                            style: const TextStyle(fontSize: 11.5, color: MFColors.green, fontFamily: kNumFont, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 6),
                      ],
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(12)),
                        child: Text(AppStrings.t('best'), style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 1)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 9),
              GestureDetector(
                onTap: () async {
                  _toast(AppStrings.t('testing_all'));
                  await conn.connect();
                  if (mounted && conn.error != null) _toast(conn.error!);
                },
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(11)),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.refresh, size: 13, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(AppStrings.t('retest'), style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(conn.autoTest ? AppStrings.t('auto_test_on') : AppStrings.t('auto_test_off'),
                  style:  TextStyle(fontSize: 10, color: MFColors.txt3)),
              Text('${conn.nodes.length} 节点${conn.lastSpeedTestTime != null ? ' · ${conn.lastSpeedTestTime} 测速' : ''}',
                  style:  TextStyle(fontSize: 10, color: MFColors.txt3, fontFamily: kNumFont)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRegionGrid(ConnectionController conn) {
    final byCountry = SpeedTester.bestLatencyByCountry(conn.nodes);
    // 国家列表：有测速结果的国家 + 常见国家兜底
    final countries = <(String, String)>[
      ('HK', '香港'), ('JP', '日本'), ('SG', '新加坡'), ('TW', '台湾'),
      ('KR', '韩国'), ('US', '美国'), ('GB', '英国'), ('DE', '德国'),
    ];
    final available = <(String, String)>[];
    for (final c in countries) {
      if (byCountry.containsKey(c.$1)) available.add(c);
    }
    final list = available.isEmpty ? countries.take(4).toList() : available;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(AppStrings.t('quick_region'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const Spacer(),
             Text('点按即切换该国最优节点', style: TextStyle(fontSize: 10, color: MFColors.txt3)),
          ],
        ),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 7,
          crossAxisSpacing: 7,
          childAspectRatio: 1.55,
          children: [
            // 自动最优
            _regionTile(conn, null, AppStrings.t('auto_best'), conn.current?.latencyMs ?? -1, isAuto: true),
            for (final (code, name) in list)
              _regionTile(conn, code, name, byCountry[code] ?? -1),
          ],
        ),
      ],
    );
  }

  Widget _regionTile(ConnectionController conn, String? code, String name, int latencyMs,
      {bool isAuto = false}) {
    final active = isAuto
        ? conn.current != null && conn.current!.countryCode == null
        : conn.current?.countryCode == nameToCode(name);
    return GestureDetector(
      onTap: () async {
        if (isAuto) {
          // 自动最优：重新测速并选优
          _toast(AppStrings.t('testing_all'));
          await conn.connect();
        } else {
          // 切到该国延迟最低的节点
          final candidates = conn.nodes
              .where((n) => n.countryCode == nameToCode(name) && n.online)
              .toList()
            ..sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
          if (candidates.isEmpty) {
            _toast(AppStrings.t('region_empty'));
            return;
          }
          await conn.switchNode(candidates.first);
          _toast(AppStrings.t('switched_to', {'name': candidates.first.tag}));
        }
      },
      child: Container(
        decoration: BoxDecoration(
          gradient: isAuto ?  LinearGradient(colors: [Color(0x40455FE9), MFColors.card]) : null,
          color: isAuto ? null : MFColors.card,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: active ? MFColors.brand.withValues(alpha: .8) : MFColors.line),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isAuto)
              const Text('✨', style: TextStyle(fontSize: 17))
            else
              CountryFlag(code, size: 17),
            const SizedBox(height: 2),
            Text(name,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                    color: isAuto ? MFColors.brandLight : MFColors.txt2)),
            const SizedBox(height: 1),
            Text(latencyMs >= 0 ? '$latencyMs ms' : '— ms',
                style: TextStyle(fontSize: 9.5, fontFamily: kNumFont, fontWeight: FontWeight.w600,
                    color: latencyMs >= 0 ? (latencyMs > 150 ? MFColors.amber : MFColors.green) : MFColors.txt3)),
          ],
        ),
      ),
    );
  }

  Widget _buildStats(ConnectionController conn) {
    // 实时速率由内核接入后提供（阶段 3）；当前展示占位，避免伪造数据误导用户
    final up = conn.upSpeedMbps, down = conn.downSpeedMbps;
    return Row(
      children: [
        Expanded(child: _StatCard(label: AppStrings.t('up_speed'), value: conn.status == ConnStatus.connected && up > 0 ? up.toStringAsFixed(1) : '—', unit: 'MB/s', color: MFColors.brandLight)),
        const SizedBox(width: 12),
        Expanded(child: _StatCard(label: AppStrings.t('down_speed'), value: conn.status == ConnStatus.connected && down > 0 ? down.toStringAsFixed(1) : '—', unit: 'MB/s', color: MFColors.green)),
      ],
    );
  }

  static String nameToCode(String name) {
    const map = {
      '香港': 'HK', '台湾': 'TW', '日本': 'JP', '新加坡': 'SG', '韩国': 'KR',
      '美国': 'US', '英国': 'GB', '德国': 'DE', '法国': 'FR', '澳大利亚': 'AU',
      '加拿大': 'CA', '俄罗斯': 'RU', '印度': 'IN', '泰国': 'TH', '越南': 'VN',
      '荷兰': 'NL', '瑞典': 'SE', '阿联酋': 'AE',
    };
    return map[name] ?? '';
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({required this.label, required this.icon, required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 38,
          decoration: BoxDecoration(
            gradient: selected ? MFColors.brandGradient : null,
            borderRadius: BorderRadius.circular(11),
            boxShadow: selected ? [BoxShadow(color: MFColors.brand.withValues(alpha: .4), blurRadius: 16)] : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: selected ? Colors.white : MFColors.txt2),
              const SizedBox(width: 7),
              Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Colors.white : MFColors.txt2)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.unit, required this.color});
  final String label;
  final String value;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
          color: MFColors.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: MFColors.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style:  TextStyle(fontSize: 11, color: MFColors.txt3, letterSpacing: .6)),
          const SizedBox(height: 5),
          Text.rich(TextSpan(children: [
            TextSpan(text: value,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color, fontFamily: kNumFont)),
            TextSpan(text: ' $unit', style:  TextStyle(fontSize: 11, color: MFColors.txt3)),
          ])),
        ],
      ),
    );
  }
}
