import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models/models.dart';
import '../../core/proxy/proxy_core.dart';
import '../../core/services/account_service.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/subscription_service.dart';
import '../../core/api/api_client.dart';
import '../../l10n/app_strings.dart';
import '../../core/services/geo_lookup.dart';
import '../../main.dart';
import '../../theme/app_theme.dart';
import '../../widgets/country_flag.dart';
import '../devices/devices_page.dart';
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
  /// 上一帧连接状态：用于检测「断开 → 已连接」跃迁
  bool _wasConnected = false;

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
    // 首帧兜底：进入页面时若已处于连接态（自动连接等），补触发电池引导
    WidgetsBinding.instance.addPostFrameCallback((_) => _onConnChanged());
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
    final connected = s == ConnStatus.connected;
    // 「断开 → 已连接」跃迁：隧道已建立后才引导电池豁免 —— 系统页切后台
    // 不再与 startVpn 竞争（v1.0.18 修复：避免「点连接自动缩小、连接不生效」）
    if (connected && !_wasConnected) {
      unawaited(PermissionService.instance.maybeRequestBatteryOnce());
    }
    _wasConnected = connected;
    if (connected && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!connected && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  /// 刷新账号状态 + 节点列表。
  /// 状态判定（到期/设备满/禁用）先于节点拉取完成，任何自动连接/手动连接
  /// 都能基于真实状态拦截——不会出现「拉订阅之前就放行」的窗口。
  Future<void> _ensureNodes({bool force = false}) async {
    final conn = context.read<ConnectionController>();
    // 首次进入 / 下拉刷新时刷新账号状态（登录成功时已判定过一次，这里幂等）
    if (force || !AccountService.instance.loaded) {
      await AccountService.instance.refresh(force: force);
    }
    if (!mounted) return;
    if (conn.nodes.isNotEmpty && !force) return;
    setState(() => _loadingNodes = true);
    try {
      final nodes = await SubscriptionService.instance.fetchNodes(force: force);
      await conn.loadNodes(nodes);
      // 设置「启动时自动连接」→ 订阅加载完成后自动连接（每次启动仅一次；默认关闭）
      unawaited(conn.autoConnectIfEnabled());
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loadingNodes = false);
    }
  }

  Future<void> _toggleConnect(ConnectionController conn) async {
    unawaited(HapticFeedback.mediumImpact());
    final acc = AccountService.instance;
    if (conn.status == ConnStatus.disconnecting) {
      return; // 正在断开，忽略点击
    } else if (conn.status == ConnStatus.connected) {
      unawaited(conn.disconnect());
    } else if (conn.status == ConnStatus.testing ||
        conn.status == ConnStatus.connecting ||
        conn.status == ConnStatus.reconnecting) {
      unawaited(conn.disconnect());
      _toast(AppStrings.t('cancel_connect'));
    } else if (acc.isBlocked) {
      // 到期 / 设备满 / 被禁用 / 未开通：先给对应提示，绝不放行
      // （状态在登录/进入主页时已判定，这里不依赖节点拉取结果）
      _showBlockedDialog(acc);
    } else if (conn.nodes.isEmpty) {
      _toast(AppStrings.t('no_nodes'));
    } else {
      // 连接前：VPN 授权 + 通知 + 电池优化豁免（最高权限，防断连/防杀后台）
      final ok = await PermissionService.instance.ensureAllForConnect();
      if (!ok) {
        _toast(AppStrings.t('vpn_permission_needed'));
        return;
      }
      unawaited(conn.connect());
    }
  }

  /// 受限账号（到期/设备满/禁用/未开通）弹窗 → 一键跳对应处理页
  void _showBlockedDialog(AccountService acc) {
    final emoji = switch (acc.status) {
      AccountStatus.expired => '⏰',
      AccountStatus.deviceFull => '📱',
      AccountStatus.accountDisabled || AccountStatus.subscriptionDisabled => '🚫',
      AccountStatus.noSubscription => '🛒',
      _ => '⚠️',
    };
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
        title: Text('$emoji\n${acc.blockTitle}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.4)),
        content: Text(acc.blockText,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: MFColors.txt, height: 1.7)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          if (acc.status == AccountStatus.accountDisabled ||
              acc.status == AccountStatus.subscriptionDisabled) ...[
            // 被禁用：不可购买/不可连接，只给关闭
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppStrings.t('ok_btn')),
            ),
          ] else ...[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppStrings.t('cancel')),
            ),
            if (acc.status == AccountStatus.deviceFull) ...[
              // 设备超限：先给「管理设备」（删旧设备），再给「升级设备套餐」
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DevicesPage()));
                },
                child: Text(AppStrings.t('manage_devices'),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: MFColors.brand,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              onPressed: () {
                Navigator.pop(context);
                mainTabIndex.value = 2; // 跳到购买套餐（到期续费 / 升级设备 / 开通）
              },
              child: Text(
                switch (acc.status) {
                  AccountStatus.deviceFull =>
                    AppStrings.t('go_upgrade_devices'),
                  AccountStatus.noSubscription =>
                    AppStrings.t('go_purchase'),
                  _ => AppStrings.t('go_renew'),
                },
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final acc = context.watch<AccountService>();
    final connected = conn.status == ConnStatus.connected;
    final busy = conn.status == ConnStatus.testing || conn.status == ConnStatus.connecting || conn.status == ConnStatus.disconnecting;
    final compact = MediaQuery.of(context).size.height < 820;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _ensureNodes(force: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 22),
            children: [
              _buildHeader(),
              SizedBox(height: compact ? 4 : 6),
              _buildSubInfoBar(acc),
              SizedBox(height: compact ? 8 : 12),
              if (acc.isBlocked) ...[
                _buildAccountBanner(acc),
                SizedBox(height: compact ? 8 : 12),
              ],
              _buildConnectCard(conn, connected, busy, compact),
              SizedBox(height: compact ? 8 : 12),
              _buildModeSwitch(conn),
              SizedBox(height: compact ? 8 : 14),
              _buildStats(conn),
              SizedBox(height: compact ? 8 : 14),
              _buildQuickCountries(conn),
              SizedBox(height: compact ? 8 : 14),
              _buildAutoTestCard(conn),
              SizedBox(height: compact ? 10 : 16),
            ],
          ),
        ),
      ),
    );
  }

  /// 订阅信息条：到期时间 / 设备数量 / 剩余天数。
  /// 颜色随账号状态变化（到期红 / 设备满橙 / 禁用红），正常态品牌蓝。
  Widget _buildSubInfoBar(AccountService acc) {
    final sub = acc.sub;
    final status = acc.status;
    final expired = status == AccountStatus.expired;
    final deviceFull = status == AccountStatus.deviceFull;
    final disabled = status == AccountStatus.accountDisabled ||
        status == AccountStatus.subscriptionDisabled;
    final warn = expired || deviceFull || disabled;
    String expireText = AppStrings.t('expire_na');
    if (sub?.expireTime != null) {
      final dt = sub!.expireTime!;
      expireText = '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }
    if (expired) expireText = AppStrings.t('expired_short');
    final deviceText = sub == null
        ? '—'
        : '${sub.currentDevices} / ${sub.deviceLimit}';
    final daysText = sub == null ? '—' : '${sub.remainingDays}';
    final color = disabled
        ? MFColors.red
        : expired
            ? MFColors.red
            : deviceFull
                ? MFColors.amber
                : MFColors.brand;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        gradient: warn
            ? LinearGradient(colors: [color.withValues(alpha: .18), color.withValues(alpha: .05)])
            : const LinearGradient(colors: [Color(0x2E455FE9), Color(0x10455FE9)]),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withValues(alpha: warn ? .55 : .4)),
      ),
      child: Row(
        children: [
          _InfoCell(label: AppStrings.t('home_sub_expire'), value: expireText, flex: 2),
          _InfoCell(label: AppStrings.t('home_sub_devices'), value: deviceText, flex: 2),
          _InfoCell(
            label: AppStrings.t('home_sub_days'),
            value: sub == null ? '—' : '$daysText ${AppStrings.t('days')}',
            flex: 2,
            highlight: !warn && !expired,
          ),
        ],
      ),
    );
  }

  /// 受限账号顶部引导条：只有「确实受限」才出现，且按钮按状态区分 ——
  /// 到期→去续费；设备满→升级设备/管理设备；禁用→无购买按钮；未开通→去开通。
  /// 正常账号节点加载失败等临时问题不再被引导去购买（原实现按 nodes.isEmpty 判断）。
  Widget _buildAccountBanner(AccountService acc) {
    final status = acc.status;
    final (Color color, Color soft) = switch (status) {
      AccountStatus.expired => (MFColors.red, const Color(0x2EFF5A5F)),
      AccountStatus.deviceFull => (MFColors.amber, const Color(0x33FFB020)),
      AccountStatus.accountDisabled ||
      AccountStatus.subscriptionDisabled =>
        (MFColors.red, const Color(0x2EFF5A5F)),
      AccountStatus.noSubscription => (MFColors.amber, const Color(0x33FFB020)),
      _ => (MFColors.brand, const Color(0x2E455FE9)),
    };
    final emoji = switch (status) {
      AccountStatus.expired => '⏰',
      AccountStatus.deviceFull => '📱',
      AccountStatus.accountDisabled ||
      AccountStatus.subscriptionDisabled =>
        '🚫',
      AccountStatus.noSubscription => '🛒',
      _ => 'ℹ️',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [soft, color.withValues(alpha: .06)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 9),
          Expanded(
            child: Text(acc.blockText,
                style: TextStyle(fontSize: 12, color: MFColors.txt, height: 1.5)),
          ),
          if (status != AccountStatus.accountDisabled &&
              status != AccountStatus.subscriptionDisabled)
            GestureDetector(
              onTap: () {
                if (status == AccountStatus.deviceFull) {
                  // 设备满：管理设备（删除旧设备）优先级最高，次选升级
                  Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DevicesPage()));
                } else {
                  mainTabIndex.value = 2;
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                    gradient: MFColors.brandGradient,
                    borderRadius: BorderRadius.circular(10)),
                child: Text(
                  switch (status) {
                    AccountStatus.expired => AppStrings.t('go_renew'),
                    AccountStatus.deviceFull =>
                      AppStrings.t('manage_devices'),
                    _ => AppStrings.t('go_purchase'),
                  },
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openNodePicker(ConnectionController conn) {
    if (conn.nodes.isEmpty) {
      _toast(AppStrings.t('no_nodes'));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MFColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final sorted = List.of(conn.nodes)
          ..sort((a, b) {
            if (a.online != b.online) return a.online ? -1 : 1;
            if (a.latencyMs < 0 && b.latencyMs < 0) return a.tag.compareTo(b.tag);
            if (a.latencyMs < 0) return 1;
            if (b.latencyMs < 0) return -1;
            return a.latencyMs.compareTo(b.latencyMs);
          });
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.62,
          minChildSize: 0.35,
          maxChildSize: 0.9,
          builder: (_, scroll) => Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: MFColors.line2,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Row(
                  children: [
                    Text(AppStrings.t('nodes_title'),
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text(AppStrings.t('tap_switch_node'),
                        style: TextStyle(fontSize: 11, color: MFColors.txt3)),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  itemCount: sorted.length,
                  itemBuilder: (_, i) {
                    final n = sorted[i];
                    final isCurrent = conn.current?.tag == n.tag;
                    final latencyColor = !n.online
                        ? MFColors.red
                        : (n.latencyMs < 0
                            ? MFColors.txt3
                            : (n.latencyMs < 100 ? MFColors.green : MFColors.amber));
                    return GestureDetector(
                      onTap: () async {
                        Navigator.pop(ctx);
                        await conn.switchNode(n);
                        if (mounted) _toast(AppStrings.t('switched_to', {'name': n.tag}));
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                        decoration: BoxDecoration(
                          color: isCurrent ? MFColors.brand.withValues(alpha: .09) : MFColors.card2,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isCurrent ? MFColors.brand.withValues(alpha: .55) : MFColors.line,
                          ),
                        ),
                        child: Row(
                          children: [
                            CountryFlag(n.countryCode, size: 18),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(n.tag,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                            ),
                            Text(
                              n.online && n.latencyMs >= 0 ? '${n.latencyMs} ms' : '—',
                              style: TextStyle(
                                fontSize: 12,
                                color: latencyColor,
                                fontFamily: kNumFont,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (isCurrent) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.check_circle, size: 16, color: MFColors.brandLight),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
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

  Widget _buildConnectCard(ConnectionController conn, bool connected, bool busy, bool compact) {
    final acc = AccountService.instance;
    // 未连接时也展示「将连接」的线路：取当前选中，没有则默认列表第一个在线节点，
    // 避免有节点的正常用户看到「暂无节点/去开通」的误导（原实现 current==null 时误报）
    final node = conn.current ??
        (conn.nodes.isNotEmpty
            ? conn.nodes.firstWhere((n) => n.online, orElse: () => conn.nodes.first)
            : null);
    final statusColor = busy
        ? MFColors.amber
        : (connected ? MFColors.green : MFColors.txt3);
    final statusLabel = switch (conn.status) {
      ConnStatus.testing => AppStrings.t('testing'),
      ConnStatus.connecting => AppStrings.t('connecting'),
      ConnStatus.disconnecting => AppStrings.t('disconnecting_status'),
      ConnStatus.reconnecting => AppStrings.t('reconnecting'),
      ConnStatus.connected =>
        conn.speedTesting ? AppStrings.t('connected_speed_testing') : AppStrings.t('connected'),
      ConnStatus.error => AppStrings.t('error'),
      _ => AppStrings.t('disconnected'),
    };
    return Container(
      padding: EdgeInsets.fromLTRB(16, compact ? 12 : 20, 16, compact ? 10 : 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        // #1 背景浅化：品牌蓝紫柔光渐变（不再深黑难辨）
        gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0x38455FE9), Color(0x0F455FE9), Color(0x0AFFFFFF)]),
        border: Border.all(
            color: connected ? MFColors.green.withValues(alpha: .55) : MFColors.brand.withValues(alpha: .45)),
      ),
      child: Column(
        children: [
          Text(statusLabel,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: statusColor)),
          SizedBox(height: compact ? 8 : 14),
          GestureDetector(
            onTap: () => _toggleConnect(conn),
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) {
                  final glow = connected ? _pulse.value : 1.0;
                  return Container(
                    width: compact ? 80 : 108,
                    height: compact ? 80 : 108,
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
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: connected
                        ? const RadialGradient(colors: [Color(0xFF1E3B3A), Color(0xFF0E1716)], stops: [0, .75])
                        : const RadialGradient(colors: [Color(0xFF1B2233), Color(0xFF0E121B)], stops: [0, .75]),
                    border: Border.all(
                        color: connected ? MFColors.green.withValues(alpha: .5) : MFColors.line2,
                        width: 1.2),
                  ),
                  child: Center(
                    child: busy
                        ? SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: statusColor,
                            ),
                          )
                        : Icon(
                            Icons.power_settings_new_rounded,
                            size: compact ? 34 : 44,
                            color: connected ? MFColors.green : MFColors.txt2,
                          ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? 10 : 16),
          if (node != null)
            GestureDetector(
              onTap: () => _openNodePicker(conn),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: MFColors.card2.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: MFColors.line),
                ),
                child: Row(
                  children: [
                    CountryFlag(node.countryCode, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(conn.current == null
                              ? AppStrings.t('will_connect_node')
                              : AppStrings.t('current_node'),
                              style: TextStyle(fontSize: 10, color: MFColors.txt3)),
                          const SizedBox(height: 2),
                          Text(node.tag,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    if (node.latencyMs >= 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: MFColors.green.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: MFColors.green.withValues(alpha: .25)),
                        ),
                        child: Text('${node.latencyMs} ms',
                            style: const TextStyle(
                                fontSize: 12,
                                color: MFColors.green,
                                fontFamily: kNumFont,
                                fontWeight: FontWeight.w600)),
                      ),
                    const SizedBox(width: 6),
                    // #2 明显的切换箭头（整行可点）
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: MFColors.brand.withValues(alpha: .22),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: MFColors.brand.withValues(alpha: .5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(AppStrings.t('node_switch'),
                              style: const TextStyle(fontSize: 11.5, color: MFColors.brandLight, fontWeight: FontWeight.w700)),
                          const SizedBox(width: 2),
                          const Icon(Icons.chevron_right, size: 15, color: MFColors.brandLight),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            // 无任何节点：受限状态由顶部横幅解释（不引导去开通）；
            // 正常账号节点拉取失败 → 给「重试」而非「去开通」
            Column(
              children: [
                Text(
                  acc.isBlocked
                      ? AppStrings.t('no_nodes')
                      : (_loadingNodes
                          ? AppStrings.t('loading')
                          : AppStrings.t('nodes_empty_retry')),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: MFColors.txt3, height: 1.5),
                ),
                if (!acc.isBlocked && !_loadingNodes) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () => _ensureNodes(force: true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                      decoration: BoxDecoration(
                          color: MFColors.brand.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: MFColors.brand.withValues(alpha: .4))),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.refresh, size: 13, color: MFColors.brandLight),
                          const SizedBox(width: 4),
                          Text(AppStrings.t('retry_btn'),
                              style: const TextStyle(fontSize: 11.5, color: MFColors.brandLight, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          if (connected && conn.realCountry != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CountryFlag(conn.realCountry, size: 13, rounded: true),
                const SizedBox(width: 5),
                Text('${AppStrings.t('real_exit')} · ${GeoLookupService.countryName(conn.realCountry)}',
                    style: const TextStyle(fontSize: 11, color: MFColors.green)),
              ],
            ),
          ],
          if (conn.error != null) ...[
            const SizedBox(height: 8),
            Text(conn.error!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: MFColors.red, height: 1.5)),
            // 受限状态（自动连接被账号门禁拦截）错误区不放「重试」——
            // 顶部横幅已给续费/升级/管理入口；点电源键也会弹对应说明弹窗
            if (!acc.isBlocked) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => conn.connect(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(10)),
                  child: Text(AppStrings.t('retry_btn'),
                      style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
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

  Widget _buildStats(ConnectionController conn) {
    return ValueListenableBuilder<SpeedSnapshot>(
      valueListenable: conn.speedNotifier,
      builder: (context, snap, _) {
        final connected = conn.status == ConnStatus.connected;
        final up = connected ? snap.upMbps : 0.0;
        final down = connected ? snap.downMbps : 0.0;
        return Row(
          children: [
            Expanded(
              child: _StatCard(
                label: AppStrings.t('up_speed'),
                value: _formatSpeed(up, connected),
                unit: _speedUnit(up, connected),
                icon: Icons.arrow_upward_rounded,
                color: MFColors.brandLight,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: AppStrings.t('down_speed'),
                value: _formatSpeed(down, connected),
                unit: _speedUnit(down, connected),
                icon: Icons.arrow_downward_rounded,
                color: MFColors.green,
              ),
            ),
          ],
        );
      },
    );
  }

  String _formatSpeed(double mbps, bool connected) {
    if (!connected) return '0.0';
    if (mbps <= 0) return '0.0';
    if (mbps < 0.1) return (mbps * 1024).toStringAsFixed(0);
    return mbps.toStringAsFixed(1);
  }

  String _speedUnit(double mbps, bool connected) {
    if (!connected || mbps <= 0) return 'MB/s';
    if (mbps < 0.1) return 'KB/s';
    return 'MB/s';
  }

  /// 快速切换国家：点按即切该国延迟最优的在线节点
  Widget _buildQuickCountries(ConnectionController conn) {
    // 按国家聚合出最佳在线节点（最多 6 国）
    final byCountry = <String, ProxyNode>{};
    for (final n in conn.nodes) {
      if (!n.online || n.latencyMs < 0) continue;
      final code = n.countryCode ?? 'XX';
      final cur = byCountry[code];
      if (cur == null || n.latencyMs < cur.latencyMs) byCountry[code] = n;
    }
    final entries = byCountry.entries.toList()
      ..sort((a, b) => a.value.latencyMs.compareTo(b.value.latencyMs));
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(AppStrings.t('quick_switch_country'),
              style: TextStyle(fontSize: 11.5, color: MFColors.txt2)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in entries.take(6))
              GestureDetector(
                onTap: () async {
                  await conn.switchNode(e.value);
                  if (mounted) _toast(AppStrings.t('switched_to', {'name': e.value.tag}));
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    color: conn.current?.countryCode == e.key
                        ? MFColors.brand.withValues(alpha: .2)
                        : MFColors.card,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                        color: conn.current?.countryCode == e.key
                            ? MFColors.brand.withValues(alpha: .7)
                            : MFColors.line),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CountryFlag(e.key, size: 15),
                      const SizedBox(width: 6),
                      Text(GeoLookupService.countryName(e.key),
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: conn.current?.countryCode == e.key
                                  ? MFColors.brandLight
                                  : MFColors.txt)),
                      const SizedBox(width: 5),
                      Text('${e.value.latencyMs}ms',
                          style: TextStyle(
                              fontSize: 10,
                              color: MFColors.txt3,
                              fontFamily: kNumFont)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// 自动测速开关卡（连接后后台测速选优，不阻塞连接）
  Widget _buildAutoTestCard(ConnectionController conn) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0x29455FE9), Color(0x0A455FE9)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MFColors.brand.withValues(alpha: .35)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(9)),
            child: const Icon(Icons.bolt, size: 16, color: Colors.white),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppStrings.t('auto_test_title'),
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                Text(
                  conn.lastSpeedTestTime == null
                      ? AppStrings.t('auto_test_desc')
                      : '${AppStrings.t('last_test')} ${conn.lastSpeedTestTime}',
                  style: TextStyle(fontSize: 10, color: MFColors.txt3),
                ),
              ],
            ),
          ),
          Switch(
            value: conn.autoTest,
            activeTrackColor: MFColors.brand,
            onChanged: (v) => conn.setAutoTest(v),
          ),
        ],
      ),
    );
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
  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    required this.icon,
  });
  final String label;
  final String value;
  final String unit;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: MFColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MFColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12, color: MFColors.txt2, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontFamily: kNumFont,
                      height: 1)),
              const SizedBox(width: 6),
              Text(unit, style: TextStyle(fontSize: 13, color: MFColors.txt3, fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ),
    );
  }
}




/// #3 顶部信息条单元格（窄屏自动收缩，不溢出）
class _InfoCell extends StatelessWidget {
  const _InfoCell({required this.label, required this.value, this.flex = 1, this.highlight = false});
  final String label;
  final String value;
  final int flex;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: highlight ? MFColors.green : MFColors.txt,
                fontFamily: kNumFont,
              )),
          const SizedBox(height: 3),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, color: MFColors.txt2)),
        ],
      ),
    );
  }
}
