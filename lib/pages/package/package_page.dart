import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/api/endpoints.dart';
import '../../core/models/models.dart';
import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/proxy/proxy_core.dart';
import '../../core/services/subscription_service.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../payment/payment_dialog.dart';

/// 购买套餐：上下列表模式（每行 = 名称/说明/价格/购买）＋ 支付方式。
/// 真实链路：选套餐 → 下单 → 发起支付 → 二维码轮询 → paid 后刷新订阅
class PackagePage extends StatefulWidget {
  const PackagePage({super.key});

  @override
  State<PackagePage> createState() => _PackagePageState();
}

class _PackagePageState extends State<PackagePage> {
  List<Plan> _plans = [];
  List<PayMethod> _methods = [];
  bool _loading = true;
  int? _selectedPlan;
  int? _selectedMethod;
  bool _paying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final plans = await ApiClient.instance.get(Endpoints.packages);
      final methods = await PaymentService.instance.methods();
      if (mounted) {
        setState(() {
          _plans = (plans is List ? plans : [])
              .map((e) => Plan.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList()
            ..sort((a, b) => a.price.compareTo(b.price));
          _methods = methods;
          _selectedPlan = _plans.isEmpty
              ? null
              : (_plans.indexWhere((p) => p.isRecommended) >= 0
                  ? _plans.indexWhere((p) => p.isRecommended)
                  : 0);
          _selectedMethod = _methods.isEmpty ? null : 0;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _toast(ApiClient.errorMsg(e));
      }
    }
  }

  double get _amount =>
      _selectedPlan == null ? 0.0 : _plans[_selectedPlan!].price;

  /// 下单 → 支付 → 二维码 → 轮询 → 开通
  Future<void> _pay() async {
    final plan = _selectedPlan == null ? null : _plans[_selectedPlan!];
    final method = _selectedMethod == null ? null : _methods[_selectedMethod!];
    if (plan == null) return _toast(AppStrings.t('select_plan'));
    if (method == null) return _toast(AppStrings.t('select_pay'));
    setState(() => _paying = true);
    try {
      final order = await OrderService.instance.create(packageId: plan.id);
      final orderId = (order['id'] as num?)?.toInt() ?? 0;
      final orderNo = order['order_no']?.toString() ?? '';
      if (orderId == 0) throw Exception(AppStrings.t('order_failed'));

      final pay = await OrderService.instance.pay(orderId: orderId, paymentMethodId: method.id);
      if (pay.qrCode.isEmpty) throw Exception(AppStrings.t('no_qrcode'));

      if (!mounted) return;
      final paid = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PaymentQrDialog(
          qrContent: pay.qrCode,
          orderNo: pay.orderNo.isEmpty ? orderNo : pay.orderNo,
          amount: _amount,
          methodName: method.name,
          onPaid: () {},
        ),
      );
      if (paid == true && mounted) {
        _toast(AppStrings.t('activated'));
        try {
          final nodes = await SubscriptionService.instance.fetchNodes(force: true);
          if (mounted) {
            await context.read<ConnectionController>().loadNodes(nodes);
          }
        } catch (_) {}
      }
    } catch (e) {
      _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _periodLabel(Plan p) {
    if (p.durationDays >= 365) return '/年';
    if (p.durationDays >= 90) return '/季';
    return '/月';
  }

  String _desc(Plan p) {
    final parts = <String>[
      '${p.durationDays} 天',
      '${p.deviceLimit} 设备',
      AppStrings.t('unlimited'),
    ];
    if (p.description != null && p.description!.isNotEmpty) {
      final manual = p.description!
          .replaceAll('有效期 ', '')
          .replaceAll('天 | ', ' 天 · ')
          .replaceAll(' | ', ' · ');
      return manual;
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: MFColors.brand))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
                  children: [
                    Text(AppStrings.t('purchase_title'),
                        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(AppStrings.t('purchase_sub'),
                        style: TextStyle(fontSize: 12, color: MFColors.txt3)),
                    const SizedBox(height: 16),
                    if (_plans.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: Center(
                            child: Text(AppStrings.t('no_plans'),
                                style: TextStyle(fontSize: 13, color: MFColors.txt3))),
                      )
                    else ...[
                      // #6 上下列表模式
                      for (var i = 0; i < _plans.length; i++) _buildPlanRow(i, _plans[i]),
                      const SizedBox(height: 6),
                      Text(AppStrings.t('pay_methods'),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: MFColors.txt2)),
                      const SizedBox(height: 10),
                      if (_methods.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(AppStrings.t('no_pay_methods'),
                              style: TextStyle(fontSize: 12.5, color: MFColors.txt3)),
                        )
                      else
                        for (var i = 0; i < _methods.length; i++) _buildMethod(i, _methods[i]),
                      const SizedBox(height: 10),
                      Text(AppStrings.t('pay_hint'),
                          style: TextStyle(fontSize: 10.5, color: MFColors.txt3, height: 1.6)),
                      const SizedBox(height: 18),
                      // 合计 + 支付
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                            color: MFColors.card, borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: MFColors.line)),
                        child: Row(
                          children: [
                            Text(AppStrings.t('total'),
                                style: TextStyle(fontSize: 13, color: MFColors.txt2)),
                            const Spacer(),
                            Text.rich(TextSpan(children: [
                              TextSpan(text: '¥', style: TextStyle(fontSize: 14, color: MFColors.txt3)),
                              TextSpan(text: _amount.toStringAsFixed(1),
                                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, fontFamily: kNumFont)),
                            ])),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      MFPrimaryButton(label: AppStrings.t('pay_now'), loading: _paying, onPressed: _paying ? null : _pay),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  /// 上下列表：整行可点选中，含名称/说明/价格/购买按钮
  Widget _buildPlanRow(int index, Plan p) {
    final selected = _selectedPlan == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedPlan = index),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(colors: [Color(0x2E455FE9), Color(0x0F455FE9)])
              : null,
          color: selected ? null : MFColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: selected ? MFColors.brand.withValues(alpha: .7) : MFColors.line,
              width: selected ? 1.3 : 1),
          boxShadow: selected
              ? [BoxShadow(color: MFColors.brand.withValues(alpha: .18), blurRadius: 22)]
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(p.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      ),
                      if (p.isRecommended) ...[
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(99)),
                          child: Text(AppStrings.t('recommended'),
                              style: TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: .5)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(_desc(p),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: MFColors.txt2, height: 1.45)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text.rich(TextSpan(children: [
                  TextSpan(text: '¥${p.price.toStringAsFixed(0)}',
                      style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          fontFamily: kNumFont,
                          color: selected ? MFColors.brandLight : MFColors.txt)),
                  TextSpan(text: _periodLabel(p), style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
                ])),
                const SizedBox(height: 7),
                GestureDetector(
                  onTap: () {
                    setState(() => _selectedPlan = index);
                    _pay();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: MFColors.brandGradient,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(AppStrings.t('buy_now'),
                        style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMethod(int index, PayMethod m) {
    final selected = _selectedMethod == index;
    final (icon, bg, label, sub) = m.isAlipay
        ? ('支', MFColors.brand.withValues(alpha: .85), AppStrings.t('alipay'), AppStrings.t('recommended_sub'))
        : m.isWechat
            ? ('微', const Color(0xFF07C160), AppStrings.t('wechat_pay'), AppStrings.t('scan_pay'))
            : m.isCrypto
                ? ('₮', const Color(0xFF2A3242), AppStrings.t('usdt'), AppStrings.t('chain_confirm'))
                : (m.name.isNotEmpty ? m.name.characters.first : '支', MFColors.card2, m.name, AppStrings.t('scan_pay'));
    return GestureDetector(
      onTap: () => setState(() => _selectedMethod = index),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? MFColors.brand.withValues(alpha: .08) : MFColors.card,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: selected ? MFColors.brand.withValues(alpha: .65) : MFColors.line),
        ),
        child: Row(
          children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: Text(icon, style: TextStyle(fontSize: m.isCrypto ? 11 : 13, color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(sub, style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
                ],
              ),
            ),
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? MFColors.brandLight : MFColors.line2, width: 2),
              ),
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.all(3),
                      child: DecoratedBox(decoration: BoxDecoration(color: MFColors.brandLight, shape: BoxShape.circle)),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
