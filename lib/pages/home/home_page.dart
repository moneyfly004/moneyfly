import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../package/upgrade_devices_page.dart';

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

  static final _pillRadius = BorderRadius.circular(99);

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
    // 冷启动即时展示：账号**正常**（非受限）且当前无节点时，先读本地磁盘缓存
    // 秒显上次的线路（不发网络请求），避免弱网下干等订阅拉取 → 首页转圈或
    // 「切换主页空白」。放在门禁判定之后：受限账号（到期/禁用/设备满）绝不
    // 秒显旧线路误导用户，仍走下方 fetchNodes → applySubscriptionNodes([])
    // 清空展示的既有链路。断开态才注入，避免覆盖已连接会话。
    if (conn.nodes.isEmpty &&
        conn.status == ConnStatus.disconnected &&
        !AccountService.instance.isBlocked) {
      final cached = await SubscriptionService.instance.loadCachedNodes();
      if (!mounted) return;
      if (cached.isNotEmpty && conn.nodes.isEmpty) {
        await conn.loadNodes(cached);
      }
    }
    if (conn.nodes.isNotEmpty && !force) return;
    setState(() => _loadingNodes = true);
    try {
      final nodes = await SubscriptionService.instance.fetchNodes(force: force);
      // 用受保护的合并入口:已连接且当前线路不在新订阅时保持现状(不打断),
      // 受限账号空列表清空展示 —— 与首页直接 loadNodes(无条件替换)区分
      await conn.applySubscriptionNodes(nodes);
      // 设置「启动时自动连接」→ 订阅加载完成后自动连接（每次启动仅一次；默认关闭）
      unawaited(conn.autoConnectIfEnabled());
    } catch (e) {
      if (mounted) {
        final msg = ApiClient.errorMsg(e);
        // 设备被踢下线：断开当前连接并清空节点，提示用户
        if (SubscriptionService.isKickedMessage(msg)) {
          await conn.disconnect();
          await conn.loadNodes(const []);
        }
        _toast(msg);
      }
    } finally {
      if (mounted) setState(() => _loadingNodes = false);
    }
  }

  Future<void> _toggleConnect(ConnectionController conn) async {
    unawaited(HapticFeedback.mediumImpact());
    final acc = AccountService.instance;
    // 模式切换(自动断开重连)期间忽略连接按钮点击,避免竞态
    if (conn.switchingMode) return;
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
      // 连接前：VPN 授权 + 通知（带首次说明框与授权失败引导卡，
      // 见 _ensurePermissionsGuided）
      final ok = await _ensurePermissionsGuided();
      if (!ok) return;
      unawaited(conn.connect());
    }
  }

  /// 连接前权限链（带引导）：
  /// 1) 尚未授权时先弹自家说明框——告诉用户接下来系统会请求 VPN 权限、
  ///    应该点「允许」，降低首次误点拒绝的概率；
  /// 2) 授权失败（点了拒绝 / 系统框被吞没有弹出）→ 底部引导卡：
  ///    重新授权 / 打开系统 VPN 设置（排查其他 VPN「始终开启」占用）/ 取消。
  /// 返回 true = 权限就绪可继续连接。桌面端 isVpnPrepared 恒 true，直接放行。
  Future<bool> _ensurePermissionsGuided() async {
    final ps = PermissionService.instance;
    // 已授权过 → 不打扰；未授权 → 先解释一次再弹系统框
    var explained = await ps.isVpnPrepared();
    while (true) {
      if (!mounted) return false;
      if (!explained) {
        explained = true; // 每轮连接流程只解释一次，后续重试直接弹系统框
        final go = await _showVpnExplainer();
        if (!go || !mounted) return false;
      }
      final ok = await ps.ensureAllForConnect();
      if (ok) return true;
      if (!mounted) return false;
      final action = await _showVpnDeniedSheet();
      switch (action) {
        case 'retry':
          continue; // 用户主动要求重试 → 再走一遍授权
        case 'settings':
          await ps.openVpnSettings();
          return false; // 用户去系统设置处理，回来后自行再点连接
        default:
          return false; // 取消/关闭引导卡
      }
    }
  }

  /// 首次连接的 VPN 授权说明框（仅在尚未授权时出现一次）
  Future<bool> _showVpnExplainer() async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.card2,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18))),
        title: Text('🔐\n${AppStrings.t('vpn_guide_title')}',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700, height: 1.4)),
        content: Text(AppStrings.t('vpn_guide_text'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: MFColors.txt, height: 1.7)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.t('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MFColors.brand,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.t('vpn_guide_ok'),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return res == true;
  }

  /// 授权失败引导卡：返回 'retry' | 'settings' | null（取消）
  Future<String?> _showVpnDeniedSheet() {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: MFColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: MFColors.line2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('🚫 ${AppStrings.t('vpn_denied_title')}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(AppStrings.t('vpn_denied_text'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5, color: MFColors.txt, height: 1.6)),
              const SizedBox(height: 8),
              Text(AppStrings.t('vpn_denied_hint_always_on'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11.5, color: MFColors.txt3, height: 1.6)),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: MFColors.brand,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: () => Navigator.pop(ctx, 'retry'),
                child: Text(AppStrings.t('re_authorize'),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: MFColors.brand.withValues(alpha: .5)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: () => Navigator.pop(ctx, 'settings'),
                child: Text(AppStrings.t('open_vpn_settings'),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppStrings.t('cancel'),
                    style: TextStyle(color: MFColors.txt3)),
              ),
            ],
          ),
        ),
      ),
    );
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
                if (acc.status == AccountStatus.deviceFull) {
                  // 设备超限 → 走「增量升级设备」页（+N 台/可选加时长/支付）
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const UpgradeDevicesPage()));
                } else {
                  mainTabIndex.value = 2; // 到期续费 / 新开通 → 套餐页
                }
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
    final acc = context.watch<AccountService>();
    final compact = MediaQuery.sizeOf(context).height < 820;
    final pad = compact ? 16.0 : 22.0;
    final gap = compact ? 8.0 : 12.0;
    final gapL = compact ? 8.0 : 14.0;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _ensureNodes(force: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: pad),
            children: [
              _buildHeader(),
              SizedBox(height: compact ? 4 : 6),
              _buildSubInfoBar(acc),
              SizedBox(height: gap),
              if (acc.isBlocked) ...[
                _buildAccountBanner(acc),
                SizedBox(height: gap),
              ],
              // 连接卡片(含模式开关)：status/current/error/speedTesting/smartMode 变化时重建
              // 注意：selector 必须包含 realCountry / realCountryFailed —— 切国家后
              // switchNode 先把 realCountry 置 null（显示「检测中」）、再写回新国家
              // 或置失败态，若 selector 不监听它们，这几次 notifyListeners 都不会
              // 触发本卡重建，「真实出口」就停留在旧显示，直到别的字段变化才被动刷新。
              Selector<ConnectionController, ({ConnStatus s, String? tag, String? err, bool st, bool sm, String? rc, bool rcf})>(
                selector: (_, c) => (s: c.status, tag: c.current?.tag, err: c.error, st: c.speedTesting, sm: c.smartMode, rc: c.realCountry, rcf: c.realCountryFailed),
                builder: (ctx, v, child) {
                  final conn = ctx.read<ConnectionController>();
                  final connected = conn.status == ConnStatus.connected;
                  final busy = conn.status == ConnStatus.testing || conn.status == ConnStatus.connecting || conn.status == ConnStatus.disconnecting || conn.switchingMode;
                  return _buildConnectCard(conn, connected, busy, compact);
                },
              ),
              SizedBox(height: gapL),
              RepaintBoundary(child: _buildStats(ConnectionController.instance)),
              SizedBox(height: gapL),
              Selector<ConnectionController, ({int nodesHash, String? curTag, String? lock})>(
                selector: (_, c) => (nodesHash: c.nodes.length, curTag: c.current?.tag, lock: c.lockedCountry),
                builder: (ctx, v, child) => _buildQuickCountries(ctx.read<ConnectionController>()),
              ),
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
          // 节点更新：显示最近成功拉取订阅的时间，点击立即刷新
          GestureDetector(
            onTap: _refreshSubManual,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(left: 6, right: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _refreshing
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.refresh, size: 15, color: color),
                  const SizedBox(height: 3),
                  Text(
                    _fmtSubTime(),
                    style: TextStyle(
                        fontSize: 10,
                        color: MFColors.txt3,
                        fontFamily: kNumFont),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _refreshing = false;

  Future<void> _refreshSubManual() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await _ensureNodes(force: true);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _fmtSubTime() {
    final t = SubscriptionService.instance.lastUpdatedAt;
    if (t == null) return '--:--';
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
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
      _ => (MFColors.brand, Color(0x2E455FE9)),
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
      builder: (_) => _NodePickerSheet(conn: conn),
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
    final statusLabel = conn.switchingMode
        ? AppStrings.t('switching_mode')
        : switch (conn.status) {
            ConnStatus.testing => AppStrings.t('testing'),
            ConnStatus.connecting => AppStrings.t('connecting'),
            ConnStatus.disconnecting => AppStrings.t('disconnecting_status'),
            ConnStatus.reconnecting => AppStrings.t('reconnecting'),
            ConnStatus.connected =>
              conn.speedTesting
                  ? AppStrings.t('connected_speed_testing')
                  : AppStrings.t('connected'),
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
          // 已连接时长 + 本次流量(独立 1s 刷新,不重建整卡)
          if (connected) ...[
            const SizedBox(height: 6),
            _SessionInfo(conn: conn),
          ],
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
                    if (node.online && node.latencyMs >= 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: mfLatencyColor(node.latencyMs, true).withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: mfLatencyColor(node.latencyMs, true).withValues(alpha: .25)),
                        ),
                        child: Text('${node.latencyMs} ms',
                            style: TextStyle(
                                fontSize: 12,
                                color: mfLatencyColor(node.latencyMs, true),
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
                              style: TextStyle(fontSize: 11.5, color: MFColors.brandLight, fontWeight: FontWeight.w700)),
                          const SizedBox(width: 2),
                          Icon(Icons.chevron_right, size: 15, color: MFColors.brandLight),
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
                          Icon(Icons.refresh, size: 13, color: MFColors.brandLight),
                          const SizedBox(width: 4),
                          Text(AppStrings.t('retry_btn'),
                              style: TextStyle(fontSize: 11.5, color: MFColors.brandLight, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          // 连接期间常驻此行：已测出→国旗+国家；检测中→占位；重试用尽仍
          // 失败→「检测失败，点按重试」（可点，手动再发起一轮检测）——
          // 不再整块消失/永远停在「检测中」，用户始终知道出口状态
          if (connected) ...[
            const SizedBox(height: 8),
            if (conn.realCountry != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CountryFlag(conn.realCountry, size: 13, rounded: true),
                  const SizedBox(width: 5),
                  Text('${AppStrings.t('real_exit')} · ${GeoLookupService.countryName(conn.realCountry)}',
                      style: TextStyle(fontSize: 11, color: MFColors.green)),
                ],
              )
            else if (conn.realCountryFailed)
              GestureDetector(
                onTap: () => conn.refreshRealCountry(force: true),
                child: Text(AppStrings.t('real_exit_failed_retry'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: MFColors.amber)),
              )
            else
              Text(AppStrings.t('real_exit_detecting'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: MFColors.txt3)),
          ],
          if (conn.error != null) ...[
            const SizedBox(height: 8),
            Text(conn.error!, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: MFColors.red, height: 1.5)),
            // 类型化失败 → 分场景引导（授权 VPN / 允许通知 / 保持前台重试）；
            // 受限状态（自动连接被账号门禁拦截）不放按钮——
            // 顶部横幅已给续费/升级/管理入口；点电源键也会弹对应说明弹窗
            if (!acc.isBlocked) ...[
              const SizedBox(height: 8),
              _buildErrorActions(conn),
            ],
          ],
          const SizedBox(height: 10),
          _buildModeSwitch(conn),
        ],
      ),
    );
  }

  /// 错误区按钮：按失败类型分场景引导
  Widget _buildErrorActions(ConnectionController conn) {
    final guide = guideForConnError(conn.errorKind);
    final actions = <Widget>[
      if (guide.foregroundHint)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(AppStrings.t('stay_foreground_hint'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, color: MFColors.amber, height: 1.5)),
        ),
    ];
    if (guide.showGrantVpn) {
      actions.add(_ErrorBtn(
          label: AppStrings.t('grant_vpn_btn'),
          onTap: () => _retryConnect(ConnErrorKind.noVpnPermission)));
    }
    if (guide.showGrantNotify) {
      actions.add(_ErrorBtn(
          label: AppStrings.t('grant_notify_btn'),
          onTap: () => _retryConnect(ConnErrorKind.noNotificationPermission)));
    }
    if (guide.showRetry) {
      actions.add(
          _ErrorBtn(label: AppStrings.t('retry_btn'), onTap: () => _retryConnect(conn.errorKind)));
    }
    if (actions.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: actions,
    );
  }

  /// 授权类失败：先引导权限（授权成功再重连）；普通失败直接重连
  Future<void> _retryConnect(ConnErrorKind kind) async {
    final conn = ConnectionController.instance;
    if (kind == ConnErrorKind.noVpnPermission ||
        kind == ConnErrorKind.noNotificationPermission) {
      final ok = await _ensurePermissionsGuided();
      if (!ok) return;
    }
    await conn.connect();
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
            onTap: conn.switchingMode ? null : () => conn.toggleMode(true),
          ),
          _ModeOption(
            label: AppStrings.t('global_mode'),
            icon: Icons.travel_explore,
            selected: !conn.smartMode,
            onTap: conn.switchingMode ? null : () => conn.toggleMode(false),
          ),
        ],
      ),
    );
  }

  Widget _buildStats(ConnectionController conn) {
    return ValueListenableBuilder<SpeedSnapshot>(
      valueListenable: conn.speedNotifier,
      builder: (context, snap, _) {
        final up = snap.upMbps;
        final down = snap.downMbps;
        return Row(
          children: [
            Expanded(
              child: _StatCard(
                label: AppStrings.t('up_speed'),
                value: _formatSpeed(up),
                unit: _speedUnit(up),
                icon: Icons.arrow_upward_rounded,
                color: MFColors.brandLight,
                spark: conn.upHistory,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: AppStrings.t('down_speed'),
                value: _formatSpeed(down),
                unit: _speedUnit(down),
                icon: Icons.arrow_downward_rounded,
                color: MFColors.green,
                spark: conn.downHistory,
              ),
            ),
          ],
        );
      },
    );
  }

  String _formatSpeed(double mbps) {
    if (mbps <= 0) return '0.0';
    if (mbps < 0.1) return (mbps * 1024).toStringAsFixed(0);
    return mbps.toStringAsFixed(1);
  }

  String _speedUnit(double mbps) {
    if (mbps <= 0) return 'MB/s';
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
            // 「自动最优」：解除国家锁定，回到全局选优
            GestureDetector(
              onTap: () async {
                await conn.unlockCountry();
                if (mounted) _toast(AppStrings.t('auto_best_activated'));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(
                  color: conn.lockedCountry == null
                      ? MFColors.green.withValues(alpha: .18)
                      : MFColors.card,
                  borderRadius: _pillRadius,
                  border: Border.all(
                      color: conn.lockedCountry == null
                          ? MFColors.green.withValues(alpha: .7)
                          : MFColors.line),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome, size: 14,
                        color: conn.lockedCountry == null ? MFColors.green : MFColors.txt2),
                    const SizedBox(width: 5),
                    Text(AppStrings.t('auto_best'),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: conn.lockedCountry == null
                                ? MFColors.green
                                : MFColors.txt)),
                  ],
                ),
              ),
            ),
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
                    borderRadius: _pillRadius,
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

}

/// 节点选择底部面板（从首页「切换」进入）。
/// 测速逐节点回填会高频 notify（~10fps），每次整表重排 O(n log n) 会把低端机
/// 主线程打满，表现为面板卡死/空白。这里把「重排」节流到 300ms，其余 notify
/// 仅重绘可见项（高亮/延迟文本），既保留实时延迟又避免卡顿。
class _NodePickerSheet extends StatefulWidget {
  const _NodePickerSheet({required this.conn});
  final ConnectionController conn;

  @override
  State<_NodePickerSheet> createState() => _NodePickerSheetState();
}

class _NodePickerSheetState extends State<_NodePickerSheet> {
  static const _sortGap = Duration(milliseconds: 300);
  List<ProxyNode> _sorted = const [];
  DateTime _lastSort = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    widget.conn.addListener(_onConnChanged);
    _sorted = List.of(widget.conn.nodes)..sort(_compare);
  }

  @override
  void dispose() {
    widget.conn.removeListener(_onConnChanged);
    super.dispose();
  }

  void _onConnChanged() {
    if (!mounted) return;
    if (DateTime.now().difference(_lastSort) >= _sortGap) {
      _resort();
    } else {
      setState(() {}); // 仅刷新高亮/延迟，不重排
    }
  }

  void _resort() {
    _lastSort = DateTime.now();
    final sorted = List.of(widget.conn.nodes)..sort(_compare);
    if (mounted) setState(() => _sorted = sorted);
  }

  static int _compare(ProxyNode a, ProxyNode b) {
    if (a.online != b.online) return a.online ? -1 : 1;
    if (a.latencyMs < 0 && b.latencyMs < 0) return a.tag.compareTo(b.tag);
    if (a.latencyMs < 0) return 1;
    if (b.latencyMs < 0) return -1;
    return a.latencyMs.compareTo(b.latencyMs);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final conn = widget.conn;
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
                const SizedBox(width: 10),
                Text(AppStrings.t('tap_switch_node'),
                    style: TextStyle(fontSize: 11, color: MFColors.txt3)),
                const Spacer(),
                // ⚡实时测速：手动挑节点时不切走（switchToBest:false），
                // 仅逐个填延迟并重排，最优浮到最上
                GestureDetector(
                  onTap: conn.speedTesting
                      ? null
                      : () => conn.retestAll(switchToBest: false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: MFColors.brandGradient,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: conn.speedTesting
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text('⚡ ${AppStrings.t('speed_test')}',
                            style: const TextStyle(
                                fontSize: 11.5,
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              itemCount: _sorted.length,
              itemBuilder: (_, i) {
                final n = _sorted[i];
                final isCurrent = conn.current?.tag == n.tag;
                final latencyColor = mfLatencyColor(n.latencyMs, n.online);
                return GestureDetector(
                  onTap: () async {
                    Navigator.pop(context);
                    await conn.switchNode(n);
                    _toast(AppStrings.t('switched_to', {'name': n.tag}));
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
                          Icon(Icons.check_circle, size: 16, color: MFColors.brandLight),
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
  }
}

class _ErrorBtn extends StatelessWidget {
  const _ErrorBtn({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
            gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(10)),
        child: Text(label,
            style: const TextStyle(
                fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption(
      {required this.label,
      required this.icon,
      required this.selected,
      this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 38,
          decoration: BoxDecoration(
            gradient: selected ? MFColors.brandGradient : null,
            borderRadius: BorderRadius.circular(11),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: MFColors.brand.withValues(alpha: .4),
                        blurRadius: 16)
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 15,
                  color: selected
                      ? Colors.white
                      : (enabled ? MFColors.txt2 : MFColors.txt3)),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? Colors.white
                          : (enabled ? MFColors.txt2 : MFColors.txt3))),
              if (!enabled) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: selected ? Colors.white70 : MFColors.txt3),
                ),
              ],
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
    this.spark,
  });
  final String label;
  final String value;
  final String unit;
  final Color color;
  final IconData icon;
  /// 迷你趋势(最近 ~60s 速率 MB/s;null 不显示)
  final List<double>? spark;

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
          if (spark != null && spark!.length >= 2) ...[
            const SizedBox(height: 10),
            SizedBox(height: 26, width: double.infinity, child: _Sparkline(values: spark!, color: color)),
          ],
        ],
      ),
    );
  }
}

/// 迷你趋势折线(无新依赖,纯 CustomPaint):平滑一条随时间变化的速率曲线
class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _SparkPainter(values: values, color: color),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.width <= 0 || size.height <= 0) return;
    var maxV = 0.0;
    for (final v in values) {
      if (v > maxV) maxV = v;
    }
    if (maxV <= 0) maxV = 0.1; // 全零也有基线
    final path = Path();
    final n = values.length;
    for (var i = 0; i < n; i++) {
      final x = size.width * i / (n - 1);
      final y = size.height - (values[i] / maxV).clamp(0.0, 1.0) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawPath(path, stroke);
    // 浅色填充(0→曲线→底部)
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: .10));
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.color != color;
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

/// 已连接会话信息(时长 + 本次上下行累计)：独立 1s 自刷新,
/// 不触发整页/整卡重建(连接卡其它内容保持静态)
class _SessionInfo extends StatefulWidget {
  const _SessionInfo({required this.conn});
  final ConnectionController conn;

  @override
  State<_SessionInfo> createState() => _SessionInfoState();
}

class _SessionInfoState extends State<_SessionInfo> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  static String _fmtMB(double mb) {
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final conn = widget.conn;
    if (conn.status != ConnStatus.connected || conn.connectedAt == null) {
      return const SizedBox.shrink();
    }
    return Text(
      '${AppStrings.t('connected_for')} ${conn.sessionUptime} · '
      '↑ ${_fmtMB(conn.sessionUpMB)} ↓ ${_fmtMB(conn.sessionDownMB)}',
      style: TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont),
    );
  }
}
