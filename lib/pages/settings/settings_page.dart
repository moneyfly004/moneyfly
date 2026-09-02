import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/crash_logger.dart';
import '../../core/services/settings_store.dart';
import '../../core/services/update_service.dart';
import '../../l10n/app_strings.dart';
import '../../main.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';
import '../auth/change_password_page.dart';

/// 设置页（设计稿 09）：完整清单 + 持久化
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic> _s = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    SettingsStore.instance.load().then((v) {
      if (mounted) {
        setState(() {
          _s = v;
          _loaded = true;
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  Future<void> _set(String key, dynamic value) async {
    setState(() => _s[key] = value);
    // 连接相关设置即时生效到连接控制器（自动测速/断线重连/默认模式）
    ConnectionController.instance.applySettings(_s);
    if (key == 'crashReport') CrashLogger.setEnabled(value == true);
    await SettingsStore.instance.save(_s);
  }

  /// 退出登录（二次确认后清会话回登录页）
  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('logout'), style: const TextStyle(fontSize: 16)),
        content: Text('确定要退出当前账号吗？', style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出', style: TextStyle(color: MFColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AuthService.instance.logout();
    if (!mounted) return;
    context.read<SessionState>().setLoggedIn(false);
  }

  /// 打开官网页面（用户协议 / 隐私政策）
  Future<void> _openUrl(String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && mounted) _toast('无法打开链接，请检查网络后重试');
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: MFColors.brand)));
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: const Text('设置'),
        actions: [
          TextButton(
            onPressed: () async {
              await SettingsStore.instance.save(const {});
              final defaults = await SettingsStore.instance.load();
              if (!mounted) return;
              setState(() => _s = defaults);
              // 默认值同步生效到连接控制器与主题
              ConnectionController.instance.applySettings(defaults);
              ThemeController.instance.setTheme(defaults['theme']?.toString() ?? 'system');
              _toast(AppStrings.t('restored'));
            },
            child: Text(AppStrings.t('restore_default'), style: TextStyle(fontSize: 12.5, color: MFColors.txt3)),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
          children: [
            _section(AppStrings.t('settings_conn')),
            _row(icon: '🔌', title: AppStrings.t('settings_auto_connect'),
                trailing: _switch(_s['autoConnect'] == true, (v) => _set('autoConnect', v))),
            _row(icon: '⚡', title: AppStrings.t('settings_auto_test'), desc: AppStrings.t('settings_auto_test_desc'),
                trailing: _switch(_s['autoTest'] == true, (v) => _set('autoTest', v))),
            _row(icon: '🔁', title: AppStrings.t('settings_reconnect'), desc: AppStrings.t('settings_reconnect_desc'),
                trailing: _switch(_s['autoReconnect'] == true, (v) => _set('autoReconnect', v))),
            _row(icon: '⏱️', title: AppStrings.t('settings_test_interval'), value: '${_s['testIntervalMin'] ?? 30} ${AppStrings.t('settings_minutes')}',
                onTap: () => _picker(['15 ${AppStrings.t('settings_minutes')}', '30 ${AppStrings.t('settings_minutes')}', '60 ${AppStrings.t('settings_minutes')}'], (v) => _set('testIntervalMin', int.parse(v.split(' ').first)))),
            _row(icon: '🌐', title: AppStrings.t('settings_dns'), value: _s['dns']?.toString() ?? '223.5.5.5',
                onTap: () => _picker(['223.5.5.5（阿里）', '1.1.1.1（Cloudflare）', '8.8.8.8（Google）'], (v) => _set('dns', v.split('（').first))),
            _row(icon: '📡', title: AppStrings.t('settings_protocol'),
                value: switch (_s['protocolFilter']?.toString()) {
                  'vless' => AppStrings.t('only_vless'),
                  'trojan' => AppStrings.t('only_trojan'),
                  _ => AppStrings.t('all_protocols'),
                },
                onTap: () => _picker([AppStrings.t('all_protocols'), AppStrings.t('only_vless'), AppStrings.t('only_trojan')], (v) => _set('protocolFilter',
                    v == AppStrings.t('only_vless') ? 'vless' : (v == AppStrings.t('only_trojan') ? 'trojan' : 'all')))),
            _section(AppStrings.t('settings_mode')),
            _row(icon: '🎯', title: AppStrings.t('settings_default_mode'),
                trailing: _seg2(
                  left: '智能', right: '全局',
                  selectedLeft: _s['defaultMode'] != 'global',
                  onLeft: () => _set('defaultMode', 'smart'),
                  onRight: () => _set('defaultMode', 'global'),
                )),
            _section(AppStrings.t('settings_network')),
            _row(icon: '🚀', title: AppStrings.t('settings_tun'),
                value: switch (_s['tunMode']?.toString()) {
                  'off' => AppStrings.t('tun_off'),
                  'force' => AppStrings.t('tun_force'),
                  _ => AppStrings.t('tun_auto'),
                },
                onTap: () => _picker([AppStrings.t('tun_auto'), AppStrings.t('tun_force'), AppStrings.t('tun_off')], (v) => _set('tunMode',
                    v == AppStrings.t('tun_force') ? 'force' : (v == AppStrings.t('tun_off') ? 'off' : 'auto')))),
            _row(icon: '🏠', title: AppStrings.t('settings_bypass_lan'),
                trailing: _switch(_s['bypassLan'] == true, (v) => _set('bypassLan', v))),
            _section(AppStrings.t('settings_appearance')),
            _row(icon: '🎨', title: AppStrings.t('settings_theme'),
                value: switch (_s['theme']?.toString()) {
                  'light' => AppStrings.t('theme_light'),
                  'dark' => '深色',
                  _ => '跟随系统',
                },
                onTap: () => _picker(['跟随系统', '深色', '浅色'], (v) {
                  final t = v == '深色' ? 'dark' : (v == '浅色' ? 'light' : 'system');
                  ThemeController.instance.setTheme(t); // 立即生效
                  _set('theme', t);
                })),
            _row(icon: '🌏', title: AppStrings.t('settings_language'),
                value: AppStrings.lang == 'en' ? 'English' : '简体中文',
                onTap: _pickLanguage),
            _section(AppStrings.t('settings_privacy')),
            _row(icon: '🔔', title: AppStrings.t('settings_notify'),
                desc: AppStrings.t('settings_notify_desc'),
                trailing: _switch(_s['notify'] == true, (v) => _set('notify', v))),
            _row(icon: '🩹', title: AppStrings.t('settings_crash'),
                desc: AppStrings.t('settings_crash_desc'),
                trailing: _switch(_s['crashReport'] == true, (v) => _set('crashReport', v))),
            _row(icon: '📊', title: AppStrings.t('settings_analytics'),
                desc: AppStrings.t('settings_analytics_desc'),
                trailing: _switch(_s['analytics'] == true, (v) => _set('analytics', v))),
            _section(AppStrings.t('settings_account')),
            _row(icon: '🔑', title: AppStrings.t('settings_change_pwd'), desc: AppStrings.t('cur_pwd'), onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChangePasswordPage()))),
            _row(icon: '⏻', title: AppStrings.t('logout'), danger: true, onTap: _logout),
            _section(AppStrings.t('settings_about')),
            _row(icon: '🔄', title: AppStrings.t('settings_check_update'), value: 'v${UpdateInfo.currentVersion}', onTap: _checkUpdate),
            _row(icon: '📄', title: AppStrings.t('settings_tos'), onTap: () => _openUrl('https://dy.moneyfly.top/terms')),
            _row(icon: '🛡️', title: AppStrings.t('settings_privacy_policy'), onTap: () => _openUrl('https://dy.moneyfly.top/privacy')),
            const SizedBox(height: 12),
             Center(
              child: Text('MoneyFly v${UpdateInfo.currentVersion} · dy.moneyfly.top',
                  style: TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
      child: Text(title,
          style:  TextStyle(fontSize: 11, color: MFColors.txt3, fontWeight: FontWeight.w700, letterSpacing: 2)),
    );
  }

  Widget _row({
    required String icon,
    required String title,
    String? desc,
    String? value,
    Widget? trailing,
    bool danger = false,
    VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 15),
      height: 52,
      decoration: BoxDecoration(
          color: MFColors.card, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: MFColors.line)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                  color: danger ? MFColors.red.withValues(alpha: .12) : const Color(0xFF1B2233),
                  borderRadius: BorderRadius.circular(9)),
              alignment: Alignment.center,
              child: Text(icon, style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500,
                          color: danger ? MFColors.red : MFColors.txt)),
                  if (desc != null) Text(desc, style:  TextStyle(fontSize: 10, color: MFColors.txt3)),
                ],
              ),
            ),
            if (value != null)
              Text(value, style:  TextStyle(fontSize: 12, color: MFColors.txt3, fontFamily: kNumFont)),
            if (value != null || onTap != null) ...[
              const SizedBox(width: 4),
               Icon(Icons.chevron_right, size: 17, color: MFColors.txt3),
            ],
            ?trailing,
          ],
        ),
      ),
    );
  }

  Widget _switch(bool value, ValueChanged<bool> onChanged) {
    return Transform.scale(scale: .82, child: Switch(value: value, onChanged: onChanged));
  }

  Widget _seg2({required String left, required String right, required bool selectedLeft,
      required VoidCallback onLeft, required VoidCallback onRight}) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: const Color(0xFF1B2233), borderRadius: BorderRadius.circular(9)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                gradient: selectedLeft ? MFColors.brandGradient : null,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(left,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: selectedLeft ? Colors.white : MFColors.txt3)),
            ),
          ),
          GestureDetector(
            onTap: onRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                gradient: selectedLeft ? null : MFColors.brandGradient,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(right,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: selectedLeft ? MFColors.txt3 : Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  /// 语言切换：简体中文 / English（立即生效）
  Future<void> _pickLanguage() async {
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        title: const Text('Language'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'zh'),
            child: Row(children: [
              Text(AppStrings.t('zh'), style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
              if (AppStrings.lang == 'zh') ...[
                const Spacer(),
                const Icon(Icons.check, size: 16, color: MFColors.brandLight),
              ],
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'en'),
            child: Row(children: [
              Text(AppStrings.t('en'), style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
              if (AppStrings.lang == 'en') ...[
                const Spacer(),
                const Icon(Icons.check, size: 16, color: MFColors.brandLight),
              ],
            ]),
          ),
        ],
      ),
    );
    if (v != null && v != AppStrings.lang) {
      await LocaleController.instance.setLang(v);
    }
  }

  bool _checkingUpdate = false;

  /// 软件升级：读后端软件库 → 比对版本 → 弹更新对话框
  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    final info = await UpdateService.instance.check();
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    if (info == null) {
      _toast('暂未配置更新源，当前已是最新版本');
      return;
    }
    if (!info.isNewer) {
      _toast('已是最新版本 v${UpdateInfo.currentVersion}');
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: !info.forced,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(info.forced ? '发现新版本（强制更新）' : '发现新版本',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(
          '当前版本 v${UpdateInfo.currentVersion}\n最新版本 v${info.latestVersion}${info.sizeText != null ? ' · ${info.sizeText}' : ''}\n\n请下载最新安装包体验新功能。',
          style:  TextStyle(fontSize: 13, color: MFColors.txt2, height: 1.7),
        ),
        actions: [
          if (!info.forced)
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('稍后')),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final url = info.downloadUrl;
              if (url == null || url.isEmpty) {
                _toast('下载链接暂未配置');
                return;
              }
              final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              if (!ok && mounted) _toast('无法打开下载链接');
            },
            child: const Text('立即下载', style: TextStyle(color: MFColors.brandLight, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Future<void> _picker(List<String> options, ValueChanged<String> onSelected) async {
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        title: const Text('请选择', style: TextStyle(fontSize: 15)),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Text(o, style:  TextStyle(fontSize: 13.5, color: MFColors.txt)),
            ),
        ],
      ),
    );
    if (v != null) onSelected(v);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
