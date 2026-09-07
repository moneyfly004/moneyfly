import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/account_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/services/subscription_service.dart';
import '../../core/services/user_service.dart';
import '../../core/proxy/proxy_core.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../payment/payment_dialog.dart';

/// 设备增量升级：设备超限时 +N 台（可选顺带 +M 天到期）。
/// 调后端 POST /orders/upgrade-devices（preview_only 算价 → 下单 → 扫码支付），
/// 支付成功后端对 device_limit 做加法、到期时间顺延，前端刷新展示。
class UpgradeDevicesPage extends StatefulWidget {
  const UpgradeDevicesPage({super.key});

  @override
  State<UpgradeDevicesPage> createState() => _UpgradeDevicesPageState();
}

class _UpgradeDevicesPageState extends State<UpgradeDevicesPage> {
  static const _deviceOptions = [1, 2, 3, 4, 5];
  static const _dayOptions = [0, 30, 90, 180, 365];

  int _addDevices = 1;
  int _addDays = 0;

  List<PayMethod> _methods = [];
  int? _selectedMethod;

  bool _loading = true;
  bool _previewing = false;
  bool _paying = false;

  double? _finalAmount;
  double? _originalAmount;
  String? _previewError;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final methods = await PaymentService.instance.methods();
      if (mounted) {
        setState(() {
          _methods = methods;
          _selectedMethod = _methods.isEmpty ? null : 0;
        });
      }
      await _preview();
    } catch (e) {
      if (mounted) {
        setState(() => _previewError = ApiClient.errorMsg(e));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  SubscriptionInfo? get _sub => AccountService.instance.sub;

  /// 推荐时长：剩余不足 45 天 → 推荐 +90 天（避免到期断连）；否则 0（仅加设备）
  int get _recommendedDays {
    final s = _sub;
    if (s == null) return 0;
    if (s.isExpired || (s.remainingDays >= 0 && s.remainingDays < 45)) return 90;
    return 0;
  }

  bool get _expired => _sub?.isExpired ?? false;

  void _onSelectionChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _preview);
  }

  Future<void> _preview() async {
    if (_loading) return;
    setState(() {
      _previewing = true;
      _previewError = null;
    });
    try {
      final r = await OrderService.instance
          .previewDeviceUpgrade(addDevices: _addDevices, addDays: _addDays);
      if (!mounted) return;
      final amt = (r['final_amount'] as num?)?.toDouble() ??
          (r['amount'] as num?)?.toDouble() ??
          0;
      final orig = (r['amount'] as num?)?.toDouble();
      setState(() {
        _finalAmount = amt;
        _originalAmount = orig;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _finalAmount = null;
          _previewError = ApiClient.errorMsg(e);
        });
      }
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _pay() async {
    final method = _selectedMethod == null ? null : _methods[_selectedMethod!];
    if (method == null) {
      _toast(AppStrings.t('select_pay'));
      return;
    }
    if (_finalAmount == null || _finalAmount! <= 0) {
      _toast(AppStrings.t('upgrade_no_amount'));
      return;
    }
    setState(() => _paying = true);
    try {
      final order = await OrderService.instance
          .createDeviceUpgrade(addDevices: _addDevices, addDays: _addDays);
      final orderId = (order['id'] as num?)?.toInt() ?? 0;
      final orderNo = order['order_no']?.toString() ?? '';
      if (orderId == 0) throw Exception(AppStrings.t('order_failed'));

      final pay = await OrderService.instance
          .pay(orderId: orderId, paymentMethodId: method.id);
      if (pay.qrCode.isEmpty) throw Exception(AppStrings.t('no_qrcode'));

      if (!mounted) return;
      final paid = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PaymentQrDialog(
          qrContent: pay.qrCode,
          orderNo: pay.orderNo.isEmpty ? orderNo : pay.orderNo,
          amount: _finalAmount ?? 0,
          methodName: method.name,
          onPaid: () {},
        ),
      );
      if (paid == true && mounted) {
        _toast(AppStrings.t('upgrade_done'));
        try {
          // 刷新账号状态（设备数/到期）与节点
          await AccountService.instance.refresh(force: true);
          UserService.instance.invalidateCache();
          final nodes =
              await SubscriptionService.instance.fetchNodes(force: true);
          if (mounted) {
            await context.read<ConnectionController>().applySubscriptionNodes(nodes);
          }
        } catch (_) {}
        if (mounted) Navigator.of(context).pop(true);
      }
    } catch (e) {
      _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _paying = false);
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
    final s = _sub;
    final limit = s?.deviceLimit ?? 0;
    final used = s?.currentDevices ?? 0;
    final expire = s?.expireTime;
    final expireText = expire == null
        ? '—'
        : '${expire.year}-${expire.month.toString().padLeft(2, '0')}-${expire.day.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('upgrade_title')),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: MFColors.brand))
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                children: [
                  // 当前订阅卡片
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0x38455FE9), Color(0x0F455FE9)]),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: MFColors.brand.withValues(alpha: .3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(AppStrings.t('upgrade_current'),
                            style: TextStyle(
                                fontSize: 11, color: MFColors.txt3)),
                        const SizedBox(height: 8),
                        Text(
                          '$used / $limit ${AppStrings.t('devices_unit')}'
                          ' · ${AppStrings.t('upgrade_expire')} $expireText',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: MFColors.txt),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(AppStrings.t('upgrade_add_devices'),
                      style: _sectionStyle()),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final n in _deviceOptions)
                        _chip(
                          '${AppStrings.t('devices_unit')} +$n',
                          _addDevices == n,
                          () {
                            setState(() => _addDevices = n);
                            _onSelectionChanged();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(AppStrings.t('upgrade_add_days'),
                          style: _sectionStyle()),
                      const Spacer(),
                      if (!_expired && _recommendedDays == 0)
                        Text(AppStrings.t('upgrade_no_days_needed'),
                            style: TextStyle(
                                fontSize: 10, color: MFColors.txt3)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final d in _dayOptions)
                        _chip(
                          d == 0
                              ? AppStrings.t('upgrade_days_only')
                              : '+$d ${AppStrings.t('days')}',
                          _addDays == d,
                          _expired && d == 0
                              ? null // 已过期必须顺带加时长
                              : () {
                                  setState(() => _addDays = d);
                                  _onSelectionChanged();
                                },
                          recommended: d == _recommendedDays,
                        ),
                    ],
                  ),
                  if (_expired)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(AppStrings.t('upgrade_expired_hint'),
                          style: TextStyle(
                              fontSize: 10.5, color: MFColors.amber)),
                    ),
                  const SizedBox(height: 16),
                  // 金额
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                        color: MFColors.card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: MFColors.line)),
                    child: Row(
                      children: [
                        Text(AppStrings.t('upgrade_amount'),
                            style: TextStyle(
                                fontSize: 13, color: MFColors.txt2)),
                        const Spacer(),
                        if (_previewing)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else if (_finalAmount != null)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (_originalAmount != null &&
                                  _originalAmount! > _finalAmount! + 0.001)
                                Padding(
                                  padding: const EdgeInsets.only(
                                      right: 6, bottom: 2),
                                  child: Text(
                                    '¥${_originalAmount!.toStringAsFixed(2)}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: MFColors.txt3,
                                        decoration:
                                            TextDecoration.lineThrough),
                                  ),
                                ),
                              Text(
                                '¥${_finalAmount!.toStringAsFixed(2)}',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: MFColors.brand,
                                    fontFamily: kNumFont),
                              ),
                            ],
                          )
                        else
                          Text('—',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: MFColors.txt3,
                                  fontFamily: kNumFont)),
                      ],
                    ),
                  ),
                  if (_previewError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_previewError!,
                          style: TextStyle(
                              fontSize: 10.5, color: MFColors.red)),
                    ),
                  const SizedBox(height: 16),
                  Text(AppStrings.t('pay_methods'),
                      style: _sectionStyle()),
                  const SizedBox(height: 8),
                  if (_methods.isEmpty)
                    Text(AppStrings.t('no_pay_methods'),
                        style:
                            TextStyle(fontSize: 12, color: MFColors.txt3))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < _methods.length; i++)
                          _payChip(i, _methods[i]),
                      ],
                    ),
                  const SizedBox(height: 20),
                  GestureDetector(
                    onTap:
                        (_paying || _finalAmount == null) ? null : _pay,
                    child: Container(
                      height: 50,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: _paying || _finalAmount == null
                            ? null
                            : MFColors.brandGradient,
                        color: _paying || _finalAmount == null
                            ? MFColors.card2
                            : null,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: _paying
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Text(
                              _finalAmount == null
                                  ? AppStrings.t('upgrade_pay_btn')
                                  : '${AppStrings.t('upgrade_pay_btn')} ¥${_finalAmount!.toStringAsFixed(2)}',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  // 禁用态(未出价/预览失败)用主题文字色,
                                  // 避免 card2 底 + 白字在浅色主题下不可读
                                  color: _paying ? Colors.white : MFColors.txt3),
                            ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(AppStrings.t('upgrade_tip'),
                      style: TextStyle(
                          fontSize: 10.5,
                          color: MFColors.txt3,
                          height: 1.6)),
                ],
              ),
      ),
    );
  }

  TextStyle _sectionStyle() => TextStyle(
      fontSize: 13, fontWeight: FontWeight.w700, color: MFColors.txt);

  Widget _chip(String label, bool selected, VoidCallback? onTap,
      {bool recommended = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          gradient: selected ? MFColors.brandGradient : null,
          color: selected ? null : MFColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected
                  ? Colors.transparent
                  : (recommended
                      ? MFColors.amber.withValues(alpha: .7)
                      : MFColors.line)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight:
                        selected || recommended ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? Colors.white
                        : (recommended ? MFColors.amber : MFColors.txt))),
            if (recommended && !selected) ...[
              const SizedBox(width: 4),
              Text(AppStrings.t('upgrade_recommend'),
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: MFColors.amber)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _payChip(int index, PayMethod m) {
    final selected = _selectedMethod == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedMethod = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? MFColors.brand.withValues(alpha: .12) : MFColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected
                  ? MFColors.brand.withValues(alpha: .7)
                  : MFColors.line),
        ),
        child: Text(m.name,
            style: TextStyle(
                fontSize: 12.5,
                color: selected ? MFColors.brand : MFColors.txt)),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
