import 'package:flutter/material.dart';

import '../../core/services/settings_store.dart';
import '../../theme/app_theme.dart';
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
    await SettingsStore.instance.save(_s);
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
              if (mounted) {
                setState(() => _s = {});
                SettingsStore.instance.load().then((v) {
                  if (mounted) setState(() => _s = v);
                });
              }
              _toast('已恢复默认设置');
            },
            child: const Text('恢复默认', style: TextStyle(fontSize: 12.5, color: MFColors.txt3)),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
          children: [
            _section('连接设置'),
            _row(icon: '🔌', title: '启动时自动连接',
                trailing: _switch(_s['autoConnect'] == true, (v) => _set('autoConnect', v))),
            _row(icon: '⚡', title: '自动测速并选最优', desc: '连接前测速全部节点',
                trailing: _switch(_s['autoTest'] == true, (v) => _set('autoTest', v))),
            _row(icon: '🔁', title: '断线自动重连', desc: '自动换最优节点重连',
                trailing: _switch(_s['autoReconnect'] == true, (v) => _set('autoReconnect', v))),
            _row(icon: '⏱️', title: '后台测速间隔', value: '${_s['testIntervalMin'] ?? 30} 分钟',
                onTap: () => _picker(['15 分钟', '30 分钟', '60 分钟'], (v) => _set('testIntervalMin', int.parse(v.split(' ').first)))),
            _row(icon: '🌐', title: 'DNS 服务器', value: _s['dns']?.toString() ?? '223.5.5.5',
                onTap: () => _picker(['223.5.5.5（阿里）', '1.1.1.1（Cloudflare）', '8.8.8.8（Google）'], (v) => _set('dns', v.split('（').first))),
            _row(icon: '📡', title: '协议过滤', value: _s['protocolFilter'] == 'all' ? '全部协议' : _s['protocolFilter'].toString(),
                onTap: () => _picker(['全部协议', '仅 vless', '仅 trojan'], (v) => _set('protocolFilter', v))),
            _section('模式'),
            _row(icon: '🎯', title: '默认模式',
                trailing: _seg2(
                  left: '智能', right: '全局',
                  selectedLeft: _s['defaultMode'] != 'global',
                  onLeft: () => _set('defaultMode', 'smart'),
                  onRight: () => _set('defaultMode', 'global'),
                )),
            _section('网络'),
            _row(icon: '🚀', title: 'TUN 虚拟网卡', value: _s['tunMode'] == 'off' ? '关闭' : '自动',
                onTap: () => _picker(['自动', '强制', '关闭'], (v) => _set('tunMode', v))),
            _row(icon: '🏠', title: '绕过局域网流量',
                trailing: _switch(_s['bypassLan'] == true, (v) => _set('bypassLan', v))),
            _section('外观'),
            _row(icon: '🎨', title: '主题', value: _s['theme']?.toString() == 'light' ? '浅色' : '跟随系统',
                onTap: () => _picker(['跟随系统', '深色', '浅色'], (v) => _set('theme', v == '深色' ? 'dark' : (v == '浅色' ? 'light' : 'system')))),
            _row(icon: '🌏', title: '语言', value: '简体中文',
                onTap: () => _toast('语言：简体中文（English 后续版本支持）')),
            _section('隐私'),
            _row(icon: '🔔', title: '允许通知', desc: '套餐到期 / 连接提醒',
                trailing: _switch(_s['notify'] == true, (v) => _set('notify', v))),
            _row(icon: '🩹', title: '崩溃日志上报',
                trailing: _switch(_s['crashReport'] == true, (v) => _set('crashReport', v))),
            _row(icon: '📊', title: '匿名使用统计',
                trailing: _switch(_s['analytics'] == true, (v) => _set('analytics', v))),
            _section('账号'),
            _row(icon: '🔑', title: '修改密码', desc: '需当前密码', onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChangePasswordPage()))),
            _row(icon: '⏻', title: '退出登录', danger: true, onTap: () => _toast('请到「我的」页退出登录')),
            _section('关于'),
            _row(icon: '🔄', title: '检查更新', value: 'v1.0.0 · 最新', onTap: () => _toast('已是最新版本')),
            _row(icon: '📄', title: '用户协议', onTap: () => _toast('《用户协议》将在官网公布')),
            _row(icon: '🛡️', title: '隐私政策', onTap: () => _toast('《隐私政策》将在官网公布')),
            const SizedBox(height: 12),
            const Center(
              child: Text('MoneyFly v1.0.0 · dy.moneyfly.top',
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
          style: const TextStyle(fontSize: 11, color: MFColors.txt3, fontWeight: FontWeight.w700, letterSpacing: 2)),
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
                  if (desc != null) Text(desc, style: const TextStyle(fontSize: 10, color: MFColors.txt3)),
                ],
              ),
            ),
            if (value != null)
              Text(value, style: const TextStyle(fontSize: 12, color: MFColors.txt3, fontFamily: kNumFont)),
            if (value != null || onTap != null) ...[
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 17, color: MFColors.txt3),
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
              child: Text(o, style: const TextStyle(fontSize: 13.5, color: MFColors.txt)),
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
