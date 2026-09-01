import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/api/endpoints.dart';
import '../../core/models/models.dart';
import '../../core/services/coupon_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/proxy/proxy_core.dart';
import '../../core/services/subscription_service.dart';
import '../../theme/app_theme.dart';
import '../payment/payment_dialog.dart';

/// 购买套餐（设计稿 04）：套餐 + 优惠码 + 支付方式（跟随官网设置，默认支付宝）
/// 真实链路：选套餐 → 输优惠码验证 → 下单 → 发起支付 → 二维码轮询 → paid 后刷新订阅
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
  final _coupon = TextEditingController();
  bool _paying = false;
  double? _discountedAmount;
  String? _couponStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _coupon.dispose();
    super.dispose();
  }

  Future<void> _load() async {
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

  double get _amount {
    final base = _selectedPlan == null ? 0.0 : _plans[_selectedPlan!].price;
    return _discountedAmount ?? base;
  }

  /// 校验优惠码（金额 + 套餐）
  Future<void> _verifyCoupon() async {
    final code = _coupon.text.trim();
    if (_selectedPlan == null) return _toast('请先选择套餐');
    if (code.isEmpty) {
      setState(() {
        _discountedAmount = null;
        _couponStatus = null;
      });
      return;
    }
    try {
      final result = await CouponService.instance.verify(
        code: code,
        amount: _plans[_selectedPlan!].price,
        packageId: _plans[_selectedPlan!].id,
      );
      final finalAmount = (result['final_amount'] as num?)?.toDouble()
          ?? (result['discounted_amount'] as num?)?.toDouble();
      if (mounted) {
        setState(() {
          _discountedAmount = finalAmount;
          _couponStatus = '优惠码已生效';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _discountedAmount = null;
          _couponStatus = null;
        });
        _toast(ApiClient.errorMsg(e));
      }
    }
  }

  /// 下单 → 支付 → 二维码 → 轮询 → 开通
  Future<void> _pay() async {
    final plan = _selectedPlan == null ? null : _plans[_selectedPlan!];
    final method = _selectedMethod == null ? null : _methods[_selectedMethod!];
    if (plan == null) return _toast('请选择套餐');
    if (method == null) return _toast('请选择支付方式');
    setState(() => _paying = true);
    try {
      final order = await OrderService.instance.create(
        packageId: plan.id,
        couponCode: _coupon.text.trim().isEmpty ? null : _coupon.text.trim(),
      );
      final orderId = (order['id'] as num?)?.toInt() ?? 0;
      final orderNo = order['order_no']?.toString() ?? '';
      if (orderId == 0) throw Exception('订单创建失败');

      final pay = await OrderService.instance.pay(orderId: orderId, paymentMethodId: method.id);
      if (pay.qrCode.isEmpty) throw Exception('未获取到支付二维码');

      if (!mounted) return;
      final paid = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PaymentQrDialog(
          qrContent: pay.qrCode,
          orderNo: pay.orderNo.isEmpty ? orderNo : pay.orderNo,
          amount: _amount,
          methodName: method.name,
          onPaid: () {
            // 支付成功：刷新订阅
            SubscriptionService.instance.fetchNodes(force: true);
            context.read<ConnectionController>().loadNodes(const []);
          },
        ),
      );
      if (paid == true && mounted) {
        _toast('开通成功！已为你准备最新节点');
        // 重新拉取订阅
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
                  padding: const EdgeInsets.fromLTRB(22, 10, 22, 24),
                  children: [
                    const Text('购买套餐', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    const Text('选择适合你的加速方案，付款后立即开通', style: TextStyle(fontSize: 12.5, color: MFColors.txt3)),
                    const SizedBox(height: 18),
                    if (_plans.isNotEmpty) _buildPlans(),
                    if (_plans.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _buildDetail(_plans[_selectedPlan ?? 0]),
                    ],
                    const SizedBox(height: 14),
                    _buildCoupon(),
                    const SizedBox(height: 18),
                    const Text('选择支付方式', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: MFColors.txt2)),
                    const SizedBox(height: 10),
                    if (_methods.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('暂无可用的支付方式，请稍后再试', style: TextStyle(fontSize: 12.5, color: MFColors.txt3)),
                      )
                    else
                      for (var i = 0; i < _methods.length; i++) _buildMethod(i, _methods[i]),
                    const SizedBox(height: 10),
                    const Text('💡 支付方式随官网设置实时同步：dy.moneyfly.top 后台启用的支付渠道会自动出现在这里，默认支付宝。',
                        style: TextStyle(fontSize: 11, color: MFColors.txt3, height: 1.6)),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                          color: MFColors.card, borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: MFColors.line)),
                      child: Row(
                        children: [
                          Text('合计（${_plans.isEmpty ? '' : _plans[_selectedPlan ?? 0].name}）',
                              style: const TextStyle(fontSize: 12.5, color: MFColors.txt2)),
                          const Spacer(),
                          if (_discountedAmount != null && _discountedAmount != _plans[_selectedPlan ?? 0].price) ...[
                            Text('¥${_plans[_selectedPlan ?? 0].price.toStringAsFixed(1)}',
                                style: const TextStyle(fontSize: 13, color: MFColors.txt3, decoration: TextDecoration.lineThrough)),
                            const SizedBox(width: 6),
                          ],
                          Text.rich(TextSpan(children: [
                            const TextSpan(text: '¥', style: TextStyle(fontSize: 14, color: MFColors.txt3)),
                            TextSpan(text: _amount.toStringAsFixed(1),
                                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, fontFamily: kNumFont)),
                          ])),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    MFPrimaryButton(label: '立即支付', loading: _paying, onPressed: _paying ? null : _pay),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildPlans() {
    return SizedBox(
      height: 118,
      child: Row(
        children: [
          for (var i = 0; i < _plans.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 9),
                child: GestureDetector(
                  onTap: () => setState(() {
                    _selectedPlan = i;
                    _discountedAmount = null;
                    _couponStatus = null;
                  }),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          gradient: _selectedPlan == i
                              ? const LinearGradient(colors: [Color(0x33455FE9), MFColors.card])
                              : null,
                          color: _selectedPlan == i ? null : MFColors.card,
                          borderRadius: BorderRadius.circular(17),
                          border: Border.all(
                              color: _selectedPlan == i ? MFColors.brand : MFColors.line,
                              width: _selectedPlan == i ? 1.4 : 1),
                          boxShadow: _selectedPlan == i
                              ? [BoxShadow(color: MFColors.brand.withValues(alpha: .25), blurRadius: 26)]
                              : null,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        child: Column(
                          children: [
                            Text(_plans[i].name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 7),
                            Text.rich(TextSpan(children: [
                              TextSpan(
                                  text: '¥${_plans[i].price.toStringAsFixed(0)}',
                                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, fontFamily: kNumFont,
                                      color: _selectedPlan == i ? MFColors.brandLight : MFColors.txt)),
                              TextSpan(text: '/${_plans[i].durationDays >= 365 ? '年' : (_plans[i].durationDays >= 90 ? '季' : '月')}',
                                  style: const TextStyle(fontSize: 11, color: MFColors.txt3)),
                            ])),
                            const SizedBox(height: 5),
                            Text('${_plans[i].durationDays} 天 · ${_plans[i].deviceLimit} 台',
                                style: const TextStyle(fontSize: 10, color: MFColors.txt3)),
                          ],
                        ),
                      ),
                      if (_plans[i].isRecommended)
                        Positioned(
                          top: -9, left: 0, right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(20)),
                              child: const Text('最划算', style: TextStyle(fontSize: 9.5, color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 1)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetail(Plan p) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
          color: MFColors.card, borderRadius: BorderRadius.circular(15), border: Border.all(color: MFColors.line)),
      child: Row(
        children: [
          _DetailItem(value: '${p.durationDays} 天', label: '套餐时长'),
          const _DetailDivider(),
          _DetailItem(value: '${p.deviceLimit} 台', label: '设备数'),
          const _DetailDivider(),
          const _DetailItem(value: '不限', label: '流量'),
          const _DetailDivider(),
          const _DetailItem(value: '680+', label: '节点'),
        ],
      ),
    );
  }

  Widget _buildCoupon() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _coupon,
                style: const TextStyle(color: MFColors.txt, fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: '优惠码（选填）',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
                ),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: _verifyCoupon,
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 17),
                decoration: BoxDecoration(
                    color: MFColors.card, borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: MFColors.line2)),
                alignment: Alignment.center,
                child: const Text('验证', style: TextStyle(fontSize: 13, color: MFColors.brandLight, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
        if (_couponStatus != null) ...[
          const SizedBox(height: 6),
          Text('✓ $_couponStatus', style: const TextStyle(fontSize: 10.5, color: MFColors.green, fontWeight: FontWeight.w600)),
        ],
      ],
    );
  }

  Widget _buildMethod(int index, PayMethod m) {
    final selected = _selectedMethod == index;
    final (icon, bg, label, sub) = m.isAlipay
        ? ('支', MFColors.brand.withValues(alpha: .85), '支付宝', '推荐 · 扫码支付')
        : m.isWechat
            ? ('微', const Color(0xFF07C160), '微信支付', '扫码支付')
            : m.isCrypto
                ? ('₮', const Color(0xFF2A3242), 'USDT 加密货币', '链上确认后开通')
                : (m.name.isNotEmpty ? m.name.characters.first : '支', MFColors.card2, m.name, '扫码支付');
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
                  Text(sub, style: const TextStyle(fontSize: 10.5, color: MFColors.txt3)),
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

class _DetailItem extends StatelessWidget {
  const _DetailItem({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(fontSize: 10, color: MFColors.txt3)),
        ],
      ),
    );
  }
}

class _DetailDivider extends StatelessWidget {
  const _DetailDivider();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 26, color: MFColors.line);
  }
}
