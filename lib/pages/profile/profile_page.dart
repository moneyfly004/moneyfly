import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/update_service.dart';
import '../../core/services/user_service.dart';
import '../../main.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../devices/devices_page.dart';
import '../notifications/notifications_page.dart';
import '../orders/orders_page.dart';
import '../settings/settings_page.dart';

/// 我的页：真实仪表盘数据（本地缓存，进入不重复刷新）+ 各功能入口
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  /// #9 本地缓存：首次加载后切回本页不再自动刷新（下拉可手动刷新）
  static DashboardInfo? _cache;
  DashboardInfo? get _dashboard => _cache;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // 无缓存才加载；已有缓存直接展示（切 tab 不再闪烁刷新）
    if (_cache == null) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await UserService.instance.dashboard();
      _cache = d;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 退出登录时清缓存，下次进入重新加载
  static void invalidateCache() => _cache = null;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final dash = _dashboard;
    final name = dash?.username ?? '—';
    final email = dash?.email ?? '';
    final balance = dash?.balance ?? 0;
    final remaining = dash?.remainingDays ?? 0;
    final expire = (dash?.expireTime ?? '').toString().isEmpty
        ? AppStrings.t('expire_na')
        : dash!.expireTime.toString();
    final online = dash?.onlineDevices ?? 0;
    final total = dash?.totalDevices ?? 0;
    final hasSub = dash?.hasSubscription == true;
    // 到期展示取日期部分
    final expireShort = expire.length > 10 ? expire.substring(0, 10) : expire;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
            children: [
              _buildHeader(name, email, balance),
              const SizedBox(height: 16),
              if (_loading && _dashboard == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator(color: MFColors.brand)),
                )
              else ...[
                if (hasSub && remaining < 7) ...[
                  _buildExpiringBanner(remaining),
                  const SizedBox(height: 12),
                ],
                // #7 浅色玻璃信息卡（不再深色看不清）
                _buildInfoCard(hasSub, remaining, expireShort, online, total),
                const SizedBox(height: 18),
                _buildMenu(context, online, total),
                const SizedBox(height: 18),
                _buildLogout(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(String name, String email, double balance) {
    return Row(
      children: [
        Container(
          width: 50, height: 50,
          decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(15)),
          child: const Icon(Icons.flight_takeoff, color: MFColors.brand, size: 26),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(email.isEmpty ? '未登录邮箱' : email,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: MFColors.txt3)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('¥${balance.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: MFColors.brandLight, fontFamily: kNumFont)),
            Text(AppStrings.t('balance'), style: TextStyle(fontSize: 9.5, color: MFColors.txt3)),
          ],
        ),
      ],
    );
  }

  /// 到期提醒（剩余 < 7 天）→ 一键续费
  Widget _buildExpiringBanner(int remaining) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0x33FFB020), Color(0x0DFFB020)]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MFColors.amber.withValues(alpha: .45)),
      ),
      child: Row(
        children: [
          const Text('⏰', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 9),
          Expanded(
            child: Text(AppStrings.t('expiring_days', {'days': '$remaining'}),
                style: TextStyle(fontSize: 12, color: MFColors.txt)),
          ),
          GestureDetector(
            onTap: () => mainTabIndex.value = 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(10)),
              child: Text(AppStrings.t('renew'), style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  /// #7 浅色信息卡：到期 / 设备 / 剩余天数 三格（柔光底色 + 清晰深色文字）
  Widget _buildInfoCard(bool hasSub, int remaining, String expire, int online, int total) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 15, 6, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0x2E455FE9), Color(0x12455FE9)]),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MFColors.brand.withValues(alpha: .38)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Text(hasSub
                    ? ((_dashboard?.membership ?? '').isNotEmpty
                        ? _dashboard!.membership
                        : AppStrings.t('member'))
                    : AppStrings.t('no_plan_yet'),
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: (hasSub ? MFColors.green : MFColors.amber).withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: (hasSub ? MFColors.green : MFColors.amber).withValues(alpha: .35)),
                  ),
                  child: Text(hasSub ? '● ${AppStrings.t('active')}' : '● ${AppStrings.t('inactive')}',
                      style: TextStyle(fontSize: 10, color: hasSub ? MFColors.green : MFColors.amber, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              _SubItem(value: '$remaining', unit: AppStrings.t('days'), label: AppStrings.t('remaining_days'), highlight: true),
              _SubItem(value: expire, label: AppStrings.t('expire_time')),
              _SubItem(value: '$online/$total', label: AppStrings.t('plan_devices')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMenu(BuildContext context, int online, int total) {
    final rows = <(String, String, String?, VoidCallback)>[
      ('📱', AppStrings.t('profile_devices'), '$online/$total', () => _push(context, const DevicesPage())),
      ('🧾', AppStrings.t('profile_orders'), null, () => _push(context, const OrdersPage())),
      ('🔔', AppStrings.t('profile_notifications'), null, () => _push(context, const NotificationsPage())),
      ('⚙️', AppStrings.t('settings'), null, () => _push(context, const SettingsPage())),
      ('ℹ️', AppStrings.t('profile_about'), 'v${UpdateInfo.currentVersion}', () => _showAbout(context)),
    ];
    return Column(
      children: [
        for (final (icon, title, badge, onTap) in rows)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            decoration: BoxDecoration(
                color: MFColors.card, borderRadius: BorderRadius.circular(15),
                border: Border.all(color: MFColors.line)),
            child: InkWell(
              borderRadius: BorderRadius.circular(15),
              onTap: onTap,
              child: Row(
                children: [
                  Text(icon, style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: MFColors.card2, borderRadius: BorderRadius.circular(12)),
                      child: Text(badge, style: TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont)),
                    ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 18, color: MFColors.txt3),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLogout(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: MFColors.card2,
            title: Text(AppStrings.t('logout'), style: TextStyle(fontSize: 16)),
            content: Text(AppStrings.t('logout_confirm'), style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.t('cancel'))),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(AppStrings.t('logout_yes'), style: TextStyle(color: MFColors.red)),
              ),
            ],
          ),
        );
        if (ok == true && context.mounted) {
          await AuthService.instance.logout();
          _ProfilePageState.invalidateCache();
          if (context.mounted) context.read<SessionState>().setLoggedIn(false);
        }
      },
      child: Container(
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: MFColors.red.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: MFColors.red.withValues(alpha: .35)),
        ),
        child: Text(AppStrings.t('logout'), style: TextStyle(fontSize: 14.5, color: MFColors.red, fontWeight: FontWeight.w600)),
      ),
    );
  }

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  void _showAbout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('profile_about')),
        content: Text('MoneyFly v${UpdateInfo.currentVersion}\n\n${AppStrings.t('slogan')}\ndy.moneyfly.top',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: MFColors.txt2, height: 1.7)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好的'))],
      ),
    );
  }
}

class _SubItem extends StatelessWidget {
  const _SubItem({required this.value, required this.label, this.unit, this.highlight = false});
  final String value;
  final String? unit;
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: highlight ? 18 : 14.5,
                      fontWeight: FontWeight.w800,
                      color: highlight ? MFColors.green : MFColors.txt,
                      fontFamily: kNumFont)),
              if (unit != null) ...[
                const SizedBox(width: 2),
                Text(unit!, style: TextStyle(fontSize: 10, color: MFColors.txt2)),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: MFColors.txt2)),
        ],
      ),
    );
  }
}
