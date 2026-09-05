import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/app_log.dart';
import '../../core/services/settings_store.dart';
import '../../core/services/update_service.dart';
import '../../l10n/app_strings.dart';
import '../../main.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';
import '../auth/change_password_page.dart';
import 'access_page.dart';
import 'bypass_page.dart';
import 'kernel_log_page.dart';
import 'kernel_page.dart';

/// 设置页（设计稿 09）：完整清单 + 持久化
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic> _s = {};
  bool _loaded = false;

  static final _rowRadius = BorderRadius.circular(14);
  static final _iconRadius = BorderRadius.circular(9);

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
    await SettingsStore.instance.save(_s);
  }

  /// 退出登录（二次确认后清会话回登录页）
  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('logout'), style: const TextStyle(fontSize: 16)),
        content: Text(AppStrings.t('logout_body'), style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('logout_btn'), style: TextStyle(color: MFColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AuthService.instance.logout();
    if (!mounted) return;
    // 设置页是 push 上来的页面：先清空路由栈回到根部，
    // 否则登录窗口会被设置页盖住，需要手动返回一步才能看到
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (!mounted) return;
    context.read<SessionState>().setLoggedIn(false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: MFColors.brand)));
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('settings_title')),
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
            if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
              _row(icon: '🚀', title: AppStrings.t('settings_launch_startup'),
                  trailing: _switch(_s['launchAtStartup'] == true, (v) async {
                    await _set('launchAtStartup', v);
                    if (v) { launchAtStartup.enable(); } else { launchAtStartup.disable(); }
                  })),
            _row(icon: '⚡', title: AppStrings.t('settings_auto_test'), desc: AppStrings.t('settings_auto_test_desc'),
                trailing: _switch(_s['autoTest'] == true, (v) => _set('autoTest', v))),
            _row(icon: '🔁', title: AppStrings.t('settings_reconnect'), desc: AppStrings.t('settings_reconnect_desc'),
                trailing: _switch(_s['autoReconnect'] == true, (v) => _set('autoReconnect', v))),
            _row(icon: '⏱️', title: AppStrings.t('settings_test_interval'), value: '${_s['testIntervalMin'] ?? 30} ${AppStrings.t('settings_minutes')}',
                onTap: () => _picker(['15 ${AppStrings.t('settings_minutes')}', '30 ${AppStrings.t('settings_minutes')}', '60 ${AppStrings.t('settings_minutes')}'], (v) => _set('testIntervalMin', int.parse(v.split(' ').first)))),
            _row(icon: '🧭', title: AppStrings.t('settings_test_url'), desc: AppStrings.t('settings_test_url_desc'),
                value: _testUrlHost(),
                onTap: _pickTestUrl),
            _row(icon: '🌐', title: AppStrings.t('settings_dns'), value: _s['dns']?.toString() ?? '223.5.5.5',
                onTap: () => _picker(['223.5.5.5（阿里）', '1.1.1.1（Cloudflare）', '8.8.8.8（Google）'], (v) => _set('dns', v.split('（').first))),
            _row(icon: '🧭', title: AppStrings.t('settings_dns_mode'),
                desc: AppStrings.t('settings_dns_mode_desc'),
                value: switch (_s['dnsMode']?.toString()) {
                  'fake-ip' => AppStrings.t('dns_mode_fakeip'),
                  'redir-host' => AppStrings.t('dns_mode_redirhost'),
                  _ => AppStrings.t('dns_mode_auto'),
                },
                onTap: () => _picker([
                  AppStrings.t('dns_mode_auto'),
                  AppStrings.t('dns_mode_fakeip'),
                  AppStrings.t('dns_mode_redirhost'),
                ], (v) => _set('dnsMode',
                    v == AppStrings.t('dns_mode_fakeip')
                        ? 'fake-ip'
                        : (v == AppStrings.t('dns_mode_redirhost')
                            ? 'redir-host'
                            : 'auto')))),
            _section(AppStrings.t('settings_mode')),
            _row(icon: '🎯', title: AppStrings.t('settings_default_mode'),
                trailing: _seg2(
                  left: '智能', right: '全局',
                  selectedLeft: _s['defaultMode'] != 'global',
                  onLeft: () => _set('defaultMode', 'smart'),
                  onRight: () => _set('defaultMode', 'global'),
                )),
            _section(AppStrings.t('settings_network')),
            _row(icon: '🔢', title: AppStrings.t('settings_local_port'),
                desc: AppStrings.t('settings_local_port_desc'),
                value: '${_s['localPort'] ?? 2080}',
                onTap: _pickLocalPort),
            _row(icon: '🔧', title: AppStrings.t('settings_clash_api_port'),
                desc: AppStrings.t('settings_clash_api_port_desc'),
                value: '${_s['clashApiPort'] ?? 9090}',
                onTap: _pickClashApiPort),
            // Android：连接强制 TUN（平台无系统代理机制），不展示可配置项
            if (!Platform.isAndroid)
              _row(icon: '🚀', title: AppStrings.t('settings_tun'),
                  desc: _tunDesc(),
                  value: switch (_s['tunMode']?.toString()) {
                    'off' => AppStrings.t('tun_off'),
                    'force' => AppStrings.t('tun_force'),
                    _ => AppStrings.t('tun_auto'),
                  },
                  onTap: _pickTunMode),
            _row(icon: '🏠', title: AppStrings.t('settings_bypass_lan'),
                trailing: _switch(_s['bypassLan'] == true, (v) => _set('bypassLan', v))),
            _row(icon: '🚫', title: AppStrings.t('settings_bypass'),
                desc: AppStrings.t('settings_bypass_desc'),
                value: '${((_s['bypassDomains'] as List?)?.length ?? 0)}',
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BypassPage()))),
            if (Platform.isAndroid)
              _row(icon: '📱', title: AppStrings.t('settings_access'),
                  desc: AppStrings.t('settings_access_desc'),
                  value: _accessModeValue(),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AccessPage()))),
            if (Platform.isAndroid)
              _row(icon: '🧱', title: AppStrings.t('settings_tun_stack'),
                  desc: AppStrings.t('settings_tun_stack_desc'),
                  value: (_s['tunStack']?.toString() ?? 'gvisor') == 'mixed'
                      ? AppStrings.t('tun_stack_mixed')
                      : AppStrings.t('tun_stack_gvisor'),
                  onTap: () => _picker([
                    AppStrings.t('tun_stack_gvisor'),
                    AppStrings.t('tun_stack_mixed'),
                  ], (v) => _set('tunStack',
                      v == AppStrings.t('tun_stack_mixed') ? 'mixed' : 'gvisor'))),
            _section(AppStrings.t('settings_kernel')),
            _row(icon: '🧩', title: AppStrings.t('settings_kernel'),
                desc: 'MetaCubeX/mihomo',
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const KernelPage()))),
            _section(AppStrings.t('settings_appearance')),
            _row(icon: '🎨', title: AppStrings.t('settings_theme'),
                value: switch (_s['theme']?.toString()) {
                  'light' => AppStrings.t('theme_light'),
                  'dark' => AppStrings.t('theme_dark'),
                  _ => AppStrings.t('theme_follow'),
                },
                onTap: () => _picker([
                  AppStrings.t('theme_follow'),
                  AppStrings.t('theme_dark'),
                  AppStrings.t('theme_light'),
                ], (v) {
                  final t = v == AppStrings.t('theme_dark')
                      ? 'dark'
                      : (v == AppStrings.t('theme_light') ? 'light' : 'system');
                  ThemeController.instance.setTheme(t); // 立即生效
                  _set('theme', t);
                })),
            _row(icon: '🌏', title: AppStrings.t('settings_language'),
                value: AppStrings.lang == 'en' ? 'English' : '简体中文',
                onTap: _pickLanguage),
            _section(AppStrings.t('settings_account')),
            _row(icon: '🔑', title: AppStrings.t('settings_change_pwd'), desc: AppStrings.t('cur_pwd'), onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChangePasswordPage()))),
            _row(icon: '⏻', title: AppStrings.t('logout'), danger: true, onTap: _logout),
            _section(AppStrings.t('settings_about')),
            _row(icon: '🔄', title: AppStrings.t('settings_check_update'), value: 'v${UpdateInfo.currentVersion}', onTap: _checkUpdate),
            _row(icon: '🧾', title: AppStrings.t('settings_kernel_log'),
                desc: AppStrings.t('settings_kernel_log_desc'),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const KernelLogPage()))),
            _row(icon: '📋', title: AppStrings.t('settings_log'), desc: AppStrings.t('settings_log_desc'), onTap: _showLog),
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
          color: MFColors.card, borderRadius: _rowRadius,
          border: Border.all(color: MFColors.line)),
      child: InkWell(
        borderRadius: _rowRadius,
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                  color: danger ? MFColors.red.withValues(alpha: .12) : MFColors.card2,
                  borderRadius: _iconRadius),
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
      decoration: BoxDecoration(color: MFColors.card2, borderRadius: BorderRadius.circular(9)),
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

  String _accessModeValue() {
    return switch (_s['accessControlMode']?.toString()) {
      'selected' => AppStrings.t('access_mode_selected'),
      'denied' => AppStrings.t('access_mode_denied'),
      _ => AppStrings.t('access_mode_all'),
    };
  }

  String? _tunDesc() {
    final mode = _s['tunMode']?.toString() ?? 'off';
    if (mode == 'off') return AppStrings.t('tun_off_hint');
    if (Platform.isAndroid || Platform.isIOS) return null;
    if (Platform.isWindows) return AppStrings.t('tun_need_admin');
    if (Platform.isMacOS) return AppStrings.t('tun_need_root');
    return null;
  }

  /// 端口输入弹窗通用件：返回合法端口；[forbidden] 返回与之冲突的值时应拒绝
  Future<int?> _askPort(String title, String hint, int cur, String invalidMsg,
      int? forbidden, {String? helper}) async {
    final ctrl = TextEditingController(text: '$cur');
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: TextStyle(color: MFColors.txt),
          decoration: InputDecoration(
            hintText: hint,
            helperText: helper ?? AppStrings.t('settings_local_port_desc'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('cancel_text')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text(AppStrings.t('save'),
                style: TextStyle(color: MFColors.brandLight)),
          ),
        ],
      ),
    );
    if (v == null || v.isEmpty) return null;
    final p = int.tryParse(v);
    if (p == null || p < 1024 || p > 65535 || (forbidden != null && p == forbidden)) {
      _toast(invalidMsg);
      return null;
    }
    return p;
  }

  /// 保存端口类设置：已连接 → 自动断开并用新值重连（内核重启后才生效）
  Future<void> _applyPortChange(String key, int value) async {
    await _set(key, value);
    final conn = ConnectionController.instance;
    if (conn.status == ConnStatus.connected) {
      _toast(AppStrings.t('local_port_reconnect'));
      unawaited(() async {
        await conn.disconnect();
        await conn.connect();
      }());
    } else {
      _toast(AppStrings.t('local_port_saved'));
    }
  }

  /// 本地代理端口（默认 2080），不能与 Clash API 端口相同
  Future<void> _pickLocalPort() async {
    final cur = (_s['localPort'] as num?)?.toInt() ?? 2080;
    final clash = (_s['clashApiPort'] as num?)?.toInt() ?? 9090;
    final p = await _askPort(AppStrings.t('settings_local_port'), '2080', cur,
        AppStrings.t('local_port_invalid'), clash);
    if (p == null) return;
    await _applyPortChange('localPort', p);
  }

  /// Clash API 管理端口（默认 9090），不能与本地代理端口相同
  Future<void> _pickClashApiPort() async {
    final cur = (_s['clashApiPort'] as num?)?.toInt() ?? 9090;
    final local = (_s['localPort'] as num?)?.toInt() ?? 2080;
    final p = await _askPort(AppStrings.t('settings_clash_api_port'), '9090', cur,
        AppStrings.t('clash_api_port_invalid'), local,
        helper: AppStrings.t('settings_clash_api_port_desc'));
    if (p == null) return;
    await _applyPortChange('clashApiPort', p);
  }

  /// 测速地址（默认谷歌 204；网络环境特殊时可改）
  Future<void> _pickTestUrl() async {
    final cur = _s['testUrl']?.toString() ?? ConnectionController.defaultTestUrl;
    final ctrl = TextEditingController(text: cur);
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('settings_test_url'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: TextStyle(color: MFColors.txt),
          decoration: InputDecoration(
            hintText: ConnectionController.defaultTestUrl,
            helperText: AppStrings.t('settings_test_url_desc'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('cancel_text')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text(AppStrings.t('save'),
                style: TextStyle(color: MFColors.brandLight)),
          ),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    final u = v.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      _toast(AppStrings.t('test_url_invalid'));
      return;
    }
    // _set 内部已同步到连接控制器（applySettings 读取 testUrl）
    await _set('testUrl', u);
  }

  /// 测速地址行展示：取 host，避免超长 URL 挤爆行
  String _testUrlHost() {
    final u = _s['testUrl']?.toString() ?? ConnectionController.defaultTestUrl;
    final host = Uri.tryParse(u)?.host;
    return (host != null && host.isNotEmpty) ? host : u;
  }

  Future<void> _pickTunMode() async {
    final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    final options = [AppStrings.t('tun_auto'), AppStrings.t('tun_force'), AppStrings.t('tun_off')];
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('tun_title'), style: TextStyle(fontSize: 15)),
        children: [
          if (isDesktop)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: MFColors.amber.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: MFColors.amber.withValues(alpha: .3)),
                ),
                child: Text(
                  Platform.isWindows
                      ? AppStrings.t('tun_win_hint')
                      : AppStrings.t('tun_mac_hint'),
                  style: TextStyle(fontSize: 11, color: MFColors.txt2, height: 1.6),
                ),
              ),
            ),
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Row(
                children: [
                  Text(o, style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
                  const Spacer(),
                  Text(
                    o == AppStrings.t('tun_off') ? AppStrings.t('tun_only_proxy') : (o == AppStrings.t('tun_force') ? AppStrings.t('tun_full_intercept') : AppStrings.t('tun_dual')),
                    style: TextStyle(fontSize: 10.5, color: MFColors.txt3),
                  ),
                ],
              ),
            ),
          // UDP/游戏提示：系统代理（HTTP）不承载 UDP，Steam/游戏需 TUN
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: MFColors.amber.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: MFColors.amber.withValues(alpha: .3)),
              ),
              child: Text(
                AppStrings.t('tun_game_tip'),
                style: TextStyle(fontSize: 11, color: MFColors.txt2, height: 1.6),
              ),
            ),
          ),
        ],
      ),
    );
    if (v != null) {
      final mode = v == AppStrings.t('tun_force') ? 'force' : (v == AppStrings.t('tun_off') ? 'off' : 'auto');
      _set('tunMode', mode);
    }
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
      _toast(AppStrings.t('latest_version', {'ver': UpdateInfo.currentVersion}));
      return;
    }
    if (!info.isNewer) {
      _toast(AppStrings.t('latest_version', {'ver': UpdateInfo.currentVersion}));
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: !info.forced,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(info.forced ? AppStrings.t('new_version_forced') : AppStrings.t('new_version'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(
          '当前版本 v${UpdateInfo.currentVersion}\n最新版本 v${info.latestVersion}${info.sizeText != null ? ' · ${info.sizeText}' : ''}\n\n请下载最新安装包体验新功能。',
          style:  TextStyle(fontSize: 13, color: MFColors.txt2, height: 1.7),
        ),
        actions: [
          if (!info.forced)
            TextButton(onPressed: () => Navigator.pop(context), child: Text(AppStrings.t('later'))),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final url = info.downloadUrl;
              if (url == null || url.isEmpty) {
                _toast(AppStrings.t('no_download_url'));
                return;
              }
              final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              if (!ok && mounted) _toast(AppStrings.t('cannot_open_url'));
            },
            child: Text(AppStrings.t('download_now'), style: TextStyle(color: MFColors.brandLight, fontWeight: FontWeight.w600)),
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
        title: Text(AppStrings.t('pick_option'), style: TextStyle(fontSize: 15)),
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

  Future<void> _showLog() async {
    final content = await AppLog.read();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Row(
          children: [
            Text(AppStrings.t('settings_log'), style: const TextStyle(fontSize: 16)),
            const Spacer(),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: content));
                if (mounted) _toast(AppStrings.t('log_copied'));
              },
              child: Text(AppStrings.t('copy'), style: const TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: () async {
                await AppLog.clear();
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                if (mounted) _toast(AppStrings.t('log_cleared'));
              },
              child: Text(AppStrings.t('clear_log'), style: const TextStyle(fontSize: 12, color: MFColors.red)),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            reverse: true,
            child: SelectableText(
              content.isEmpty ? AppStrings.t('log_empty') : content,
              style: TextStyle(fontSize: 10, color: MFColors.txt2, fontFamily: kNumFont, height: 1.6),
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogCtx), child: Text(AppStrings.t('ok_btn')))],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
