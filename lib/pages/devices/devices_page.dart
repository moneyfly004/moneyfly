import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/account_service.dart';
import '../../core/services/device_service.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_empty.dart';
import '../package/upgrade_devices_page.dart';

/// 设备管理：列表（全量）/ 删除（踢下线）/ 备注编辑 / 在线状态。
///
/// 顶部常驻「升级设备数量」入口（无论是否超限都可点：客户可增加设备名额并
/// 顺带延长到期时间）；设备在线状态以后端按最近活跃窗口计算的 online 为准
/// （不再用只增不减的 is_active 显示「永久在线」）。
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<DeviceInfo> _devices = [];
  bool _loading = true;
  int? _deletingId;
  int? _savingRemarkId;

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

  /// 编辑设备备注（输入框；可清空）
  Future<void> _editRemark(DeviceInfo device) async {
    final controller = TextEditingController(text: device.remark);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('edit_remark'), style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 200,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: AppStrings.t('remark_hint'),
            hintStyle: TextStyle(fontSize: 13, color: MFColors.txt3),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(AppStrings.t('save'),
                style: const TextStyle(color: MFColors.brandLight, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (saved == null) return; // 取消
    setState(() => _savingRemarkId = device.id);
    try {
      await DeviceService.instance.updateRemark(device.id, saved);
      await _load();
      if (mounted) _toast(AppStrings.t('remark_saved'));
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _savingRemarkId = null);
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
            : ListView(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                children: [
                  _buildUpgradeEntry(),
                  const SizedBox(height: 12),
                  if (_devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 90),
                      child: MFEmpty(
                        title: AppStrings.t('no_devices'),
                        hint: AppStrings.t('no_devices_hint'),
                      ),
                    )
                  else
                    for (var i = 0; i < _devices.length; i++) ...[
                      if (i > 0) const SizedBox(height: 10),
                      _buildDeviceCard(_devices[i]),
                    ],
                ],
              ),
      ),
    );
  }

  /// 常驻「升级设备数量」入口：无论是否超限都显示。
  /// 副文案展示当前 已用/上限 + 到期时间（升级可顺带加时长）。
  Widget _buildUpgradeEntry() {
    final sub = AccountService.instance.sub;
    final used = sub?.currentDevices ?? 0;
    final limit = sub?.deviceLimit ?? 0;
    final expire = sub?.expireTime;
    final expireText = expire == null
        ? '—'
        : '${expire.year}-${expire.month.toString().padLeft(2, '0')}-${expire.day.toString().padLeft(2, '0')}';
    final full = limit > 0 && used >= limit;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const UpgradeDevicesPage())),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [
                full ? MFColors.amber : MFColors.brand,
                MFColors.brand.withValues(alpha: .06),
              ].map((c) => c.withValues(alpha: full ? .18 : .12)).toList()),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: (full ? MFColors.amber : MFColors.brand)
                  .withValues(alpha: .5)),
        ),
        child: Row(
          children: [
            Text(full ? '📈' : '➕', style: const TextStyle(fontSize: 17)),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppStrings.t('upgrade_devices_card'),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: MFColors.txt),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    full
                        ? AppStrings.t('device_full_upgrade_banner',
                            {'used': '$used', 'limit': '$limit'})
                        : AppStrings.t('upgrade_devices_card_sub',
                            {'used': '$used', 'limit': '$limit', 'expire': expireText}),
                    style: TextStyle(
                        fontSize: 11.5, color: MFColors.txt2, height: 1.4),
                  ),
                ],
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
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
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
                  color: (d.online ? MFColors.green : MFColors.txt3)
                      .withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: (d.online ? MFColors.green : MFColors.txt3)
                          .withValues(alpha: .3)),
                ),
                child: Text(d.online ? AppStrings.t('online') : AppStrings.t('offline'),
                    style: TextStyle(
                        fontSize: 10,
                        color: d.online ? MFColors.green : MFColors.txt3,
                        fontWeight: FontWeight.w600)),
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
                icon: Icons.edit_outlined,
                label: AppStrings.t('edit_remark_btn'),
                color: MFColors.brandLight,
                loading: _savingRemarkId == d.id,
                onTap: () => _editRemark(d),
              ),
              const SizedBox(width: 8),
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
