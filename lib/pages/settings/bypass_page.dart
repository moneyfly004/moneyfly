import 'package:flutter/material.dart';

import '../../core/services/settings_store.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// 直连名单（最小规则覆盖）：名单内的域名及子域名一律不走代理、直连本地网络。
/// 用于：内网/公司域名、银行/支付 App 需要本地出口、某域名被错误代理等场景。
/// 更改在下次连接时生效。
class BypassPage extends StatefulWidget {
  const BypassPage({super.key});

  @override
  State<BypassPage> createState() => _BypassPageState();
}

class _BypassPageState extends State<BypassPage> {
  final TextEditingController _input = TextEditingController();
  List<String> _domains = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    SettingsStore.instance.load().then((s) {
      if (!mounted) return;
      setState(() {
        _domains = List<String>.from((s['bypassDomains'] as List?)?.cast<String>() ?? []);
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 规范化域名：小写、去协议头/路径/通配符前缀
  String? _normalize(String raw) {
    var d = raw.trim().toLowerCase();
    if (d.isEmpty) return null;
    for (final p in ['https://', 'http://']) {
      if (d.startsWith(p)) d = d.substring(p.length);
    }
    d = d.split('/').first.split(':').first; // 去路径与端口
    if (d.startsWith('*.')) d = d.substring(2);
    if (d.startsWith('.')) d = d.substring(1);
    if (d.isEmpty) return null;
    if (!RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')
        .hasMatch(d)) {
      return null; // 非法域名
    }
    return d;
  }

  Future<void> _add() async {
    final d = _normalize(_input.text);
    _input.clear();
    if (d == null) {
      _toast(AppStrings.t('bypass_invalid'));
      return;
    }
    if (_domains.contains(d)) {
      _toast(AppStrings.t('bypass_exists'));
      return;
    }
    setState(() => _domains.insert(0, d));
    await _save();
  }

  Future<void> _remove(String d) async {
    setState(() => _domains.remove(d));
    await _save();
  }

  Future<void> _save() async {
    try {
      final s = await SettingsStore.instance.load();
      s['bypassDomains'] = List<String>.from(_domains);
      await SettingsStore.instance.save(s);
    } catch (_) {}
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      behavior: SnackBarBehavior.floating,
      backgroundColor: MFColors.card2,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator(color: MFColors.brand)));
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('bypass_title')),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppStrings.t('bypass_desc'),
                  style: TextStyle(fontSize: 11.5, color: MFColors.txt3, height: 1.6)),
              const SizedBox(height: 12),
              // 输入行
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                          color: MFColors.card,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: MFColors.line)),
                      child: TextField(
                        controller: _input,
                        style: TextStyle(fontSize: 13.5, color: MFColors.txt),
                        decoration: InputDecoration(
                          hintText: AppStrings.t('bypass_hint'),
                          hintStyle:
                              TextStyle(fontSize: 12.5, color: MFColors.txt3),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        onSubmitted: (_) => _add(),
                        textInputAction: TextInputAction.done,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _add,
                    child: Container(
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                          gradient: MFColors.brandGradient,
                          borderRadius: BorderRadius.circular(12)),
                      alignment: Alignment.center,
                      child: Text(AppStrings.t('bypass_add'),
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                  '${AppStrings.t('bypass_count', {'n': '${_domains.length}'})}'
                  ' · ${AppStrings.t('bypass_effect')}',
                  style: TextStyle(fontSize: 11, color: MFColors.txt3)),
              const SizedBox(height: 8),
              Expanded(
                child: _domains.isEmpty
                    ? Center(
                        child: Text(AppStrings.t('bypass_empty'),
                            style: TextStyle(
                                fontSize: 12.5, color: MFColors.txt3)))
                    : ListView.separated(
                        itemCount: _domains.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final d = _domains[i];
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            height: 48,
                            decoration: BoxDecoration(
                                color: MFColors.card,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: MFColors.line)),
                            child: Row(
                              children: [
                                const Text('🌐',
                                    style: TextStyle(fontSize: 13)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(d,
                                      style: TextStyle(
                                          fontSize: 13.5,
                                          color: MFColors.txt,
                                          fontWeight: FontWeight.w500)),
                                ),
                                GestureDetector(
                                  onTap: () => _remove(d),
                                  child: Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                        color: MFColors.red
                                            .withValues(alpha: .1),
                                        borderRadius: BorderRadius.circular(9)),
                                    child: const Icon(Icons.close,
                                        size: 15, color: MFColors.red),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
