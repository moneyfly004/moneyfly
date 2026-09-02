import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/user_service.dart';
import '../../main.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../devices/devices_page.dart';
import '../notifications/notifications_page.dart';
import '../orders/orders_page.dart';
import '../settings/settings_page.dart';

/// 我的页（设计稿 06）：真实仪表盘数据 + 各功能入口
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> with WidgetsBindingObserver {
  dynamic _dashboard;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台刷新仪表盘（保活页面避免数据过期）
    if (state == AppLifecycleState.resumed && mounted) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await UserService.instance.dashboard();
      if (mounted) setState(() => _dashboard = d);
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final name = _dashboard?.username ?? '—';
    final email = _dashboard?.email ?? '';
    final balance = (_dashboard?.balance as num?)?.toDouble() ?? 0;
    final remaining = (_dashboard?.remainingDays as num?)?.toInt() ?? 0;
    final expire = _dashboard?.expireTime?.toString() ?? AppStrings.t('expire_na');
    final online = (_dashboard?.onlineDevices as num?)?.toInt() ?? 0;
    final total = (_dashboard?.totalDevices as num?)?.toInt() ?? 0;
    final hasSub = _dashboard?.hasSubscription == true;

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
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator(color: MFColors.brand)),
                )
              else ...[
                if (hasSub && remaining < 7) ...[
                  _buildExpiringBanner(remaining),
                  const SizedBox(height: 12),
                ],
                _buildSubscriptionCard(hasSub, remaining, expire, online, total),
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
          width: 54, height: 54,
          decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(16)),
          child: const Icon(Icons.flight_takeoff, color: MFColors.brand, size: 28),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            Text(email.isEmpty ? '未登录邮箱' : email, style:  TextStyle(fontSize: 12, color: MFColors.txt3)),
          ],
        ),
        const Spacer(),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('¥${balance.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: MFColors.brandLight, fontFamily: kNumFont)),
             Text(AppStrings.t('balance'), style: TextStyle(fontSize: 10, color: MFColors.txt3)),
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
                style:  TextStyle(fontSize: 12, color: MFColors.txt)),
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

  Widget _buildSubscriptionCard(bool hasSub, int remaining, String expire, int online, int total) {
    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF1A2140), Color(0xFF10141F)]),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: MFColors.brand.withValues(alpha: .4)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(hasSub ? '${_dashboard?.membership ?? ''} · ${AppStrings.t('unlimited')}'
                  : AppStrings.t('no_plan_yet'),
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: (hasSub ? MFColors.green : MFColors.amber).withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: (hasSub ? MFColors.green : MFColors.amber).withValues(alpha: .3)),
                ),
                child: Text(hasSub ? '● ${AppStrings.t('active')}' : '● ${AppStrings.t('inactive')}',
                    style: TextStyle(fontSize: 10, color: hasSub ? MFColors.green : MFColors.amber, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _SubItem(value: '$remaining 天', label: AppStrings.t('remaining_days')),
              _SubItem(value: expire.length > 12 ? expire.substring(0, 10) : expire, label: AppStrings.t('expire_time')),
              _SubItem(value: '$online / $total', label: AppStrings.t('plan_devices')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMenu(BuildContext context, int online, int total) {
    final rows = [
      ('📱', AppStrings.t('profile_devices'), '$online/$total', () => _push(context, const DevicesPage())),
      ('🧾', AppStrings.t('profile_orders'), null, () => _push(context, const OrdersPage())),
      ('🎟️', AppStrings.t('profile_coupons'), null, () => _toast(AppStrings.t('coupon_ok'))),
      ('🔔', AppStrings.t('profile_notifications'), null, () => _push(context, const NotificationsPage())),
      ('⚙️', AppStrings.t('settings'), null, () => _push(context, const SettingsPage())),
      ('ℹ️', AppStrings.t('profile_about'), null, () => _showAbout(context)),
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
                      child: Text(badge, style:  TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont)),
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
            content:  Text(AppStrings.t('logout_confirm'), style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
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
        content:  Text('MoneyFly v1.0.0\n\n${AppStrings.t('slogan')}\ndy.moneyfly.top',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: MFColors.txt2, height: 1.7)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好的'))],
      ),
    );
  }
}

class _SubItem extends StatelessWidget {
  const _SubItem({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, fontFamily: kNumFont)),
          const SizedBox(height: 3),
          Text(label, style:  TextStyle(fontSize: 10, color: MFColors.txt3)),
        ],
      ),
    );
  }
}
