import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/account_service.dart';
import '../../core/services/device_service.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../package/upgrade_devices_page.dart';

/// 设备管理：列表 / 删除（踢下线）
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<DeviceInfo> _devices = [];
  bool _loading = true;
  int? _deletingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final list = await DeviceService.instance.list();
      if (mounted) setState(() => _devices = list);
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteDevice(DeviceInfo device) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('delete_device'), style: const TextStyle(fontSize: 16)),
        content: Text(AppStrings.t('delete_device_body', {'name': device.displayName}),
            style:  TextStyle(fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('delete'), style: const TextStyle(color: MFColors.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deletingId = device.id);
    try {
      await DeviceService.instance.delete(device.id);
      await _load();
      if (mounted) _toast(AppStrings.t('device_deleted'));
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('device_manage')),
        actions: [
          TextButton(onPressed: _load, child: Text(AppStrings.t('refresh'), style: TextStyle(color: MFColors.brandLight))),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: MFColors.brand))
            : _devices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                         Text(AppStrings.t('no_devices'), style: TextStyle(fontSize: 14, color: MFColors.txt3)),
                        const SizedBox(height: 8),
                         Text(AppStrings.t('no_devices_hint'), style: TextStyle(fontSize: 12, color: MFColors.txt3)),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                    itemCount: _devices.length + (_showUpgradeBanner ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      if (_showUpgradeBanner && i == 0) {
                        return _buildUpgradeBanner();
                      }
                      return _buildDeviceCard(
                          _devices[i - (_showUpgradeBanner ? 1 : 0)]);
                    },
                  ),
      ),
    );
  }

  /// 设备名额是否已满（≥ 上限）：显示升级入口条幅
  bool get _showUpgradeBanner {
    final sub = AccountService.instance.sub;
    return sub != null &&
        sub.deviceLimit > 0 &&
        sub.currentDevices >= sub.deviceLimit;
  }

  Widget _buildUpgradeBanner() {
    final sub = AccountService.instance.sub;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const UpgradeDevicesPage())),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [
                MFColors.amber.withValues(alpha: .18),
                MFColors.brand.withValues(alpha: .08)
              ]),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: MFColors.amber.withValues(alpha: .5)),
        ),
        child: Row(
          children: [
            const Text('📈', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                AppStrings.t('device_full_upgrade_banner', {
                  'used': '${sub?.currentDevices ?? 0}',
                  'limit': '${sub?.deviceLimit ?? 0}',
                }),
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: MFColors.txt,
                    height: 1.4),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: MFColors.txt3),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCard(DeviceInfo d) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: MFColors.card, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MFColors.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                    color: MFColors.card2, borderRadius: BorderRadius.circular(11)),
                alignment: Alignment.center,
                child: Text(d.osName.isNotEmpty ? d.osName.substring(0, 1).toUpperCase() : '📱',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.remark.isNotEmpty ? d.remark : d.displayName,
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      [d.osName, d.deviceModel].where((e) => e.isNotEmpty).join(' · '),
                      style:  TextStyle(fontSize: 11, color: MFColors.txt3),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (d.isActive ? MFColors.green : MFColors.red).withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: (d.isActive ? MFColors.green : MFColors.red).withValues(alpha: .3)),
                ),
                child: Text(d.isActive ? AppStrings.t('online') : AppStrings.t('offline'),
                    style: TextStyle(fontSize: 10, color: d.isActive ? MFColors.green : MFColors.red, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              if (d.ipAddress.isNotEmpty)
                _meta('IP', d.ipAddress),
              if (d.location.isNotEmpty)
                _meta(AppStrings.t('location'), d.location),
              if (d.softwareVersion.isNotEmpty)
                _meta(AppStrings.t('version'), d.softwareVersion),
              _meta(AppStrings.t('access'), '${d.accessCount}'),
              if (d.lastSeen.isNotEmpty)
                _meta(AppStrings.t('recent'), d.lastSeen),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _ActionBtn(
                icon: Icons.delete_outline,
                label: AppStrings.t('delete'),
                color: MFColors.red,
                loading: _deletingId == d.id,
                onTap: () => _deleteDevice(d),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _meta(String k, String v) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$k ', style:  TextStyle(fontSize: 10.5, color: MFColors.txt3)),
          Text(v, style:  TextStyle(fontSize: 10.5, color: MFColors.txt2, fontFamily: kNumFont)),
        ],
      );
}

class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.loading = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: loading ? null : onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: .3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: color))
            else
              Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
