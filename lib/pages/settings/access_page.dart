import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/services/settings_store.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// 按 App 分流/排除（Android AccessControl）：
/// 控制哪些应用走代理（VpnService allowed/disallowed）。
/// 三种模式：全部走代理 / 仅勾选应用 / 排除勾选应用。
/// 更改即时保存；重连（或下次连接）后生效 —— 因为 TUN 路由在连接时建立。
class AccessPage extends StatefulWidget {
  const AccessPage({super.key});

  @override
  State<AccessPage> createState() => _AccessPageState();
}

class _AccessPageState extends State<AccessPage> {
  static const _channel = MethodChannel('top.moneyfly/vpn_core');

  List<Map<String, String>> _apps = [];
  String _mode = 'all';
  Set<String> _selected = {};
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final s = await SettingsStore.instance.load();
      _mode = s['accessControlMode']?.toString() ?? 'all';
      _selected = Set<String>.from(
          (s['accessControlApps'] as List?)?.cast<String>() ?? []);
      final raw = await _channel.invokeListMethod<Map>('getInstalledApps') ?? [];
      _apps = raw
          .map((m) => {
                'package': m['package']?.toString() ?? '',
                'label': m['label']?.toString() ?? m['package']?.toString() ?? '',
              })
          .where((m) => m['package']!.isNotEmpty)
          .toList();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    try {
      final s = await SettingsStore.instance.load();
      s['accessControlMode'] = _mode;
      s['accessControlApps'] = _selected.toList();
      await SettingsStore.instance.save(s);
    } catch (_) {}
  }

  void _setMode(String m) {
    setState(() => _mode = m);
    _save();
  }

  void _toggle(String pkg) {
    setState(() {
      if (!_selected.add(pkg)) _selected.remove(pkg);
    });
    _save();
  }

  List<Map<String, String>> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _apps;
    return _apps
        .where((a) =>
            a['label']!.toLowerCase().contains(q) ||
            a['package']!.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _reconnect() async {
    final conn = ConnectionController.instance;
    if (conn.status != ConnStatus.connected) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('access_reconnect_btn'),
            style: const TextStyle(fontSize: 16)),
        content: Text(AppStrings.t('access_saved_tip'),
            style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('access_reconnect_btn'),
                style: TextStyle(color: MFColors.brand)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await conn.disconnect();
    await conn.connect();
  }

  @override
  Widget build(BuildContext context) {
    final connected = ConnectionController.instance.status == ConnStatus.connected;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('access_title')),
        actions: [
          TextButton(
            onPressed: _reconnect,
            child: Text(
                connected
                    ? AppStrings.t('access_reconnect_btn')
                    : AppStrings.t('access_saved_tip'),
                style: TextStyle(
                    fontSize: 11.5,
                    color: connected ? MFColors.brand : MFColors.txt3)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text(AppStrings.t('access_desc'),
                  style: TextStyle(
                      fontSize: 11.5, color: MFColors.txt3, height: 1.6)),
            ),
            const SizedBox(height: 10),
            // 模式选择
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                    color: MFColors.card2,
                    borderRadius: BorderRadius.circular(11)),
                child: Row(
                  children: [
                    _modeBtn('all', AppStrings.t('access_mode_all')),
                    _modeBtn('selected', AppStrings.t('access_mode_selected')),
                    _modeBtn('denied', AppStrings.t('access_mode_denied')),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                '${AppStrings.t('access_sel_count', {'n': '${_selected.length}'})}'
                ' · ${AppStrings.t('access_saved_tip')}',
                style: TextStyle(fontSize: 10.5, color: MFColors.txt3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                    color: MFColors.card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: MFColors.line)),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(fontSize: 13, color: MFColors.txt),
                  decoration: InputDecoration(
                    hintText: AppStrings.t('access_search_hint'),
                    hintStyle: TextStyle(fontSize: 12, color: MFColors.txt3),
                    border: InputBorder.none,
                    isDense: true,
                    icon: Icon(Icons.search, size: 16, color: MFColors.txt3),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: MFColors.brand))
                  : _filtered.isEmpty
                      ? Center(
                          child: Text(AppStrings.t('access_none'),
                              style: TextStyle(
                                  fontSize: 12, color: MFColors.txt3)))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                          itemCount: _filtered.length,
                          itemBuilder: (context, i) {
                            final app = _filtered[i];
                            final pkg = app['package']!;
                            final label = app['label']!;
                            final checked =
                                _mode == 'selected' || _mode == 'denied'
                                    ? _selected.contains(pkg)
                                    : false;
                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              decoration: BoxDecoration(
                                  color: checked
                                      ? MFColors.brand.withValues(alpha: .06)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10)),
                              child: CheckboxListTile(
                                value: checked,
                                activeColor: MFColors.brand,
                                dense: true,
                                controlAffinity: ListTileControlAffinity.trailing,
                                onChanged: _mode == 'all'
                                    ? null
                                    : (_) => _toggle(pkg),
                                title: Text(label,
                                    style: TextStyle(
                                        fontSize: 13.5, color: MFColors.txt)),
                                subtitle: Text(pkg,
                                    style: TextStyle(
                                        fontSize: 9.5, color: MFColors.txt3)),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeBtn(String mode, String label) {
    final active = _mode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => _setMode(mode),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            gradient: active ? MFColors.brandGradient : null,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : MFColors.txt3),
          ),
        ),
      ),
    );
  }
}
