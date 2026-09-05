import 'package:flutter/material.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/services/kernel_manager.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// 内核管理页：显示当前内置 mihomo 版本、官方最新版本；
/// 桌面端可直接下载官方预编译内核并替换（FlClash 同款能力）。
class KernelPage extends StatefulWidget {
  const KernelPage({super.key});

  @override
  State<KernelPage> createState() => _KernelPageState();
}

class _KernelPageState extends State<KernelPage> {
  static final _radius = BorderRadius.circular(14);
  static final _iconRadius = BorderRadius.circular(9);

  String? _current;
  String? _latest;
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cur = await KernelManager.instance.detectCurrent();
    if (!mounted) return;
    setState(() => _current = cur);
    if (KernelManager.isDesktop) {
      await _check();
    }
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final latest = await KernelManager.instance.fetchLatest();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _latest = latest;
      if (latest == null) {
        _error = AppStrings.t('kernel_fetch_latest_fail', {'err': 'network'});
      }
    });
  }

  bool get _hasNewer {
    final c = _current, l = _latest;
    if (c == null || l == null) return false;
    return KernelManager.compare(l, c) > 0;
  }

  Future<void> _update() async {
    final latest = _latest;
    if (latest == null || _downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
    });
    final err = await KernelManager.instance.updateTo(latest,
        onProgress: (p) {
      if (mounted) setState(() => _progress = p);
    });
    if (!mounted) return;
    setState(() => _downloading = false);
    if (err.isEmpty) {
      setState(() => _current = latest);
      _toast(AppStrings.t('kernel_download_done', {'ver': latest}));
    } else if (err == 'kernel_running') {
      _toast(AppStrings.t('kernel_update_desc'));
    } else {
      _toast(AppStrings.t('kernel_update_fail', {'err': err}));
    }
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
    final running = ConnectionController.instance.status == ConnStatus.connected;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('kernel_title')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
          children: [
            _section(AppStrings.t('settings_kernel')),
            _row(
              icon: '🧩',
              title: AppStrings.t('kernel_current'),
              value: _current == null
                  ? AppStrings.t('kernel_version_unknown')
                  : 'v$_current',
            ),
            _row(
              icon: '⚡',
              title: AppStrings.t('kernel_running_state'),
              value: running
                  ? AppStrings.t('kernel_running')
                  : AppStrings.t('kernel_stopped'),
            ),
            if (KernelManager.isDesktop) ...[
              _section('mihomo'),
              if (_checking)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                )
              else ...[
                _row(
                  icon: '🆕',
                  title: AppStrings.t('kernel_latest'),
                  value: _latest == null
                      ? AppStrings.t('kernel_version_unknown')
                      : 'v$_latest',
                  onTap: _check,
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
                    child: Text(_error!,
                        style: TextStyle(
                            fontSize: 11, color: MFColors.red)),
                  ),
                if (_hasNewer)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    child: _row(
                      icon: '⬇️',
                      title: AppStrings.t('kernel_new_found', {'ver': 'v$_latest'}),
                      desc: AppStrings.t('kernel_update_desc'),
                      onTap: _downloading ? null : _update,
                    ),
                  )
                else if (_current != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                    child: Text(
                        AppStrings.t('kernel_up_to_date', {'ver': 'v$_current'}),
                        style: TextStyle(
                            fontSize: 12, color: MFColors.txt2)),
                  ),
                if (_downloading)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            AppStrings.t('kernel_downloading',
                                {'pct': (_progress * 100).round().toString()}),
                            style: TextStyle(
                                fontSize: 12, color: MFColors.txt2)),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: _progress,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                          backgroundColor: MFColors.card2,
                        ),
                      ],
                    ),
                  ),
              ],
            ] else ...[
              // Android：内核随 App 发布
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                child: Text(
                  AppStrings.t('kernel_android_ver',
                      {'ver': _current == null ? '?' : 'v$_current'}),
                  style: TextStyle(fontSize: 13, color: MFColors.txt),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Text(
                  AppStrings.t('kernel_android_update_tip'),
                  style: TextStyle(fontSize: 11.5, color: MFColors.txt3),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text(AppStrings.t('kernel_source'),
                style: TextStyle(
                    fontSize: 10.5, color: MFColors.txt3)),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
      child: Text(title,
          style: TextStyle(
              fontSize: 11,
              color: MFColors.txt3,
              fontWeight: FontWeight.w700,
              letterSpacing: 2)),
    );
  }

  Widget _row({
    required String icon,
    required String title,
    String? desc,
    String? value,
    VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 15),
      height: 52,
      decoration: BoxDecoration(
          color: MFColors.card,
          borderRadius: _radius,
          border: Border.all(color: MFColors.line)),
      child: InkWell(
        borderRadius: _radius,
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                  color: MFColors.card2, borderRadius: _iconRadius),
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
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: MFColors.txt)),
                  if (desc != null)
                    Text(desc,
                        style:
                            TextStyle(fontSize: 10, color: MFColors.txt3)),
                ],
              ),
            ),
            if (value != null)
              Text(value,
                  style: TextStyle(
                      fontSize: 12,
                      color: MFColors.txt3,
                      fontFamily: kNumFont)),
            if (value != null || onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 17, color: MFColors.txt3),
            ],
          ],
        ),
      ),
    );
  }
}
