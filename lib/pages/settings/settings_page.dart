import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/services/app_log.dart';
import '../../core/services/crash_logger.dart';
import '../../core/services/settings_store.dart';
import '../../core/services/subscription_service.dart';
import '../../core/services/update_service.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/mf_input.dart';
import '../auth/change_password_page.dart';
import 'access_page.dart';
import 'bypass_page.dart';
import 'geo_update_page.dart';
import 'kernel_page.dart';
import 'log_center_page.dart';

/// 主 DNS 列表默认值（阿里 223.5.5.5 + 腾讯 119.29.29.29，国内可达）
const _defaultDnsServers = ['223.5.5.5', '119.29.29.29'];

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
    // 基于最新值只改这一键再保存(update 单写队列),避免整份旧快照回写
    // 覆盖其它模块(如 lastSelectedTag/kernelVariant)刚写入的值
    await SettingsStore.instance.update((s) => s[key] = value);
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
              await SettingsStore.instance.reset();
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
            // ① 连接与线路：用什么模式连、怎么自动连/重连/测速
            _section(AppStrings.t('group_connect')),
            _row(icon: '🎯', title: AppStrings.t('settings_default_mode'),
                trailing: _seg2(
                  left: AppStrings.t('smart_mode'), right: AppStrings.t('global_mode'),
                  selectedLeft: _s['defaultMode'] != 'global',
                  onLeft: () => _set('defaultMode', 'smart'),
                  onRight: () => _set('defaultMode', 'global'),
                )),
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
            // ② 代理与分流：TUN、DNS、直连名单、按应用分流
            _section(AppStrings.t('group_proxy')),
            if (!Platform.isAndroid)
              _row(icon: '🚀', title: AppStrings.t('settings_tun'),
                  desc: _tunDesc(),
                  value: switch (_s['tunMode']?.toString()) {
                    'off' => AppStrings.t('tun_off'),
                    'force' => AppStrings.t('tun_force'),
                    _ => AppStrings.t('tun_auto'),
                  },
                  onTap: _pickTunMode),
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
            // 主 DNS 列表（逗号分隔文本编辑；旧 'dns' 单值键保留兼容，主列表优先）
            _row(icon: '🌐', title: AppStrings.t('settings_dns'),
                desc: AppStrings.t('settings_dns_desc'),
                value: _dnsList().join(', '),
                onTap: _pickDnsList),
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
            // fake-ip 过滤追加（这些域名保留真实解析，不映射 fake-ip）
            _row(icon: '🧩', title: AppStrings.t('settings_fakeip_extra'),
                desc: AppStrings.t('settings_fakeip_extra_desc'),
                value: '${_fakeIpExtra().length}',
                onTap: _pickFakeIpFilter),
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
            // ③ 网络与端口（低频/高级）
            _section(AppStrings.t('group_network')),
            _row(icon: '🔢', title: AppStrings.t('settings_local_port'),
                desc: AppStrings.t('settings_local_port_desc'),
                value: '${_s['localPort'] ?? 2080}',
                onTap: _pickLocalPort),
            _row(icon: '🔧', title: AppStrings.t('settings_clash_api_port'),
                desc: AppStrings.t('settings_clash_api_port_desc'),
                value: '${_s['clashApiPort'] ?? 9090}',
                onTap: _pickClashApiPort),
            // ④ 内核与数据
            _section(AppStrings.t('group_kernel')),
            _row(icon: '🧩', title: AppStrings.t('settings_kernel'),
                desc: 'MetaCubeX/mihomo',
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const KernelPage()))),
            _row(icon: '🌍', title: AppStrings.t('settings_geo_data'),
                desc: AppStrings.t('settings_geo_data_desc'),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GeoUpdatePage()))),
            // ⑤ 外观
            _section(AppStrings.t('group_appearance')),
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
            // ⑥ 账户
            _section(AppStrings.t('group_account')),
            _row(icon: '🔑', title: AppStrings.t('settings_change_pwd'), desc: AppStrings.t('cur_pwd'), onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChangePasswordPage()))),
            _row(icon: '🧹', title: AppStrings.t('settings_clear_data'),
                desc: AppStrings.t('settings_clear_data_desc'),
                danger: true,
                onTap: _clearLocalData),
            // ⑦ 关于与诊断
            _section(AppStrings.t('group_about')),
            _row(icon: '🔄', title: AppStrings.t('settings_check_update'), value: 'v${UpdateInfo.currentVersion}', onTap: _checkUpdate),
            _row(icon: '📋', title: AppStrings.t('log_center_title'),
                desc: AppStrings.t('log_center_desc'),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogCenterPage()))),
            _row(icon: '💥', title: AppStrings.t('settings_crash_report'),
                desc: AppStrings.t('settings_crash_report_desc'),
                trailing: _switch(_s['crashReport'] == true, (v) {
                  setState(() => _s['crashReport'] = v);
                  CrashLogger.setEnabled(v);
                  _set('crashReport', v);
                })),
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
              Flexible(
                child: Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: MFColors.txt3,
                        fontFamily: kNumFont)),
              ),
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
          decoration: mfInput(
            hint: hint,
            helper: helper ?? AppStrings.t('settings_local_port_desc'),
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
          decoration: mfInput(
            hint: ConnectionController.defaultTestUrl,
            helper: AppStrings.t('settings_test_url_desc'),
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

  /// 生效的主 DNS 列表：dnsNameservers（新，主列表）> dns（旧单值兼容）> 默认
  List<String> _dnsList() {
    final stored = _s['dnsNameservers'];
    if (stored is List && stored.isNotEmpty) {
      return List<String>.from(stored.whereType<String>());
    }
    final legacy = _s['dns']?.toString().trim() ?? '';
    if (legacy.isNotEmpty && legacy != '223.5.5.5') return [legacy];
    return List<String>.from(_defaultDnsServers);
  }

  /// fake-ip 过滤追加域名列表（SettingsStore['fakeIpFilterExtra']）
  List<String> _fakeIpExtra() {
    final l = _s['fakeIpFilterExtra'];
    return l is List
        ? List<String>.from(l.whereType<String>())
        : const <String>[];
  }

  /// 逗号（半/全角）、换行分隔的 DNS 文本 → 去空白、去重、保序的列表
  static List<String> _splitServerText(String v) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in v.split(RegExp(r'[,，\r\n]+'))) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  bool _isIpv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    for (final o in parts) {
      if (o.isEmpty) return false;
      if (o.length > 1 && o.startsWith('0')) return false;
      final n = int.tryParse(o);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  /// 主机名（单/多标签，可带结尾点；DNS 域名/DoH host 都走这里）
  bool _isHostname(String s) {
    if (s.isEmpty || s.length > 253 || s.contains('..')) return false;
    return RegExp(
            r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.?$')
        .hasMatch(s);
  }

  /// 单个 DNS 服务器是否合法：IPv4 / IPv6 / 域名 / DoH·DoT 带协议 URL
  bool _isValidDnsServer(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    // https://dns.alidns.com/dns-query、tls://dns.google 等带协议地址
    if (t.contains('://')) {
      final u = Uri.tryParse(t);
      return u != null && u.host.isNotEmpty;
    }
    if (t.contains(':')) {
      // IPv6（可带 [ ]）
      final v6 = t.replaceAll('[', '').replaceAll(']', '');
      if (RegExp(r'^[0-9a-fA-F:]+$').hasMatch(v6) &&
          (v6.contains('::') || ':'.allMatches(v6).length >= 2)) {
        return true;
      }
      return false; // host:port 形式的内核 nameserver 不支持
    }
    return _isIpv4(t) || _isHostname(t);
  }

  /// 主 DNS 列表编辑（逗号/换行分隔文本），合法才保存
  Future<void> _pickDnsList() async {
    final ctrl = TextEditingController(text: _dnsList().join(', '));
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('settings_dns'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          minLines: 2,
          maxLines: 5,
          style: TextStyle(color: MFColors.txt),
          decoration: mfInput(hint: AppStrings.t('dns_list_hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: Text(AppStrings.t('save'),
                style: TextStyle(color: MFColors.brandLight)),
          ),
        ],
      ),
    );
    if (v == null) return;
    final servers = _splitServerText(v);
    if (servers.isEmpty) {
      _toast(AppStrings.t('dns_list_required'));
      return;
    }
    for (var i = 0; i < servers.length; i++) {
      if (!_isValidDnsServer(servers[i])) {
        _toast(AppStrings.t('dns_list_invalid', {'n': '${i + 1}'}));
        return;
      }
    }
    await _set('dnsNameservers', servers);
  }

  /// 规范化 fake-ip 过滤条目：小写，可选 `*.` 前缀，须为合法域名
  String? _normalizeFakeIpPattern(String raw) {
    var p = raw.trim().toLowerCase();
    var wildcard = false;
    if (p.startsWith('*.')) {
      wildcard = true;
      p = p.substring(2);
    }
    if (p.startsWith('.')) p = p.substring(1);
    if (!_isHostname(p)) return null;
    return wildcard ? '*.$p' : p;
  }

  /// fake-ip 过滤追加域名编辑（每行一个；域名保留真实解析）
  Future<void> _pickFakeIpFilter() async {
    final ctrl = TextEditingController(text: _fakeIpExtra().join('\n'));
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('settings_fakeip_extra'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.multiline,
          minLines: 3,
          maxLines: 6,
          style: TextStyle(color: MFColors.txt, fontSize: 13),
          decoration: mfInput(hint: AppStrings.t('fakeip_extra_hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: Text(AppStrings.t('save'),
                style: TextStyle(color: MFColors.brandLight)),
          ),
        ],
      ),
    );
    if (v == null) return;
    final items = _splitServerText(v);
    final out = <String>[];
    for (var i = 0; i < items.length; i++) {
      final norm = _normalizeFakeIpPattern(items[i]);
      if (norm == null) {
        _toast(AppStrings.t('fakeip_invalid', {'line': '${i + 1}'}));
        return;
      }
      out.add(norm);
    }
    await _set('fakeIpFilterExtra', out);
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

  /// 清除本地数据（订阅配置缓存 / 节点 / 运行日志）：
  /// 断开连接 → 清内存与磁盘订阅缓存 → 清日志。保留登录状态，
  /// 下次进入节点页会重新拉取最新订阅（配合到期/禁用后强制刷新，
  /// 避免旧配置残留；卸载前清空也用它）。
  Future<void> _clearLocalData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('settings_clear_data'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(AppStrings.t('clear_data_confirm'),
            style: TextStyle(fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('confirm'),
                style: const TextStyle(color: MFColors.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final conn = ConnectionController.instance;
      if (conn.status == ConnStatus.connected ||
          conn.status == ConnStatus.connecting ||
          conn.status == ConnStatus.reconnecting) {
        await conn.disconnect();
      }
      // 清订阅缓存（内存 + 磁盘）
      SubscriptionService.instance.clearCache();
      // 清内存节点展示（下次进入节点页/首页会自动重新拉取）
      await conn.loadNodes(const []);
      // 清运行日志
      await AppLog.clear();
      if (mounted) _toast(AppStrings.t('clear_data_done'));
    } catch (_) {
      if (mounted) _toast(AppStrings.t('clear_data_failed'));
    }
  }

  /// 软件升级：读后端软件库 → 比对版本 → 弹更新对话框
  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    final info = await UpdateService.instance.check();
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    if (info == null) {
      // 网络/后端失败不能当成"已是最新"
      _toast(AppStrings.t('check_update_fail'));
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
          AppStrings.t('update_body', {
            'cur': 'v${UpdateInfo.currentVersion}',
            'latest': 'v${info.latestVersion}',
            'size': info.sizeText != null ? ' · ${info.sizeText}' : '',
          }),
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

void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
