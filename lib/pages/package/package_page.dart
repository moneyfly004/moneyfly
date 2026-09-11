import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/account_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/proxy/proxy_core.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/mf_empty.dart';
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
  String? _error; // 加载失败(与"暂无套餐"区分)

  @override
  void initState() {
    super.initState();
    _initLoad();
  }

  /// 冷启动：先展示磁盘缓存（不再整页转圈），再后台静默刷新；无缓存才走网络 loading。
  Future<void> _initLoad() async {
    final cached = await PaymentService.instance.loadCatalog();
    if (!mounted) return;
    if (cached != null) {
      PaymentService.instance.adoptCatalog(cached.plans, cached.methods);
      _apply(cached.plans, cached.methods);
    }
    await _load();
  }

  Future<void> _load() async {
    final hadCache = _plans.isNotEmpty || _methods.isNotEmpty;
    if (!hadCache) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // plans 与 methods 相互独立，并发发起再一起 await，省一次串行往返
      final plansF = PaymentService.instance.plans(force: true);
      final methodsF = PaymentService.instance.methods(force: true);
      final plans = await plansF;
      final methods = await methodsF;
      if (mounted) _apply(plans, methods);
    } catch (e) {
      // 有缓存时静默失败：保留旧目录继续浏览
      if (mounted && !hadCache) {
        setState(() {
          _loading = false;
          _error = ApiClient.errorMsg(e);
        });
      }
    }
  }

  void _apply(List<Plan> plans, List<PayMethod> methods) {
    if (!mounted) return;
    setState(() {
      _plans = plans;
      _methods = methods;
      _selectedPlan = _plans.isEmpty
          ? null
          : (_plans.indexWhere((p) => p.isRecommended) >= 0
              ? _plans.indexWhere((p) => p.isRecommended)
              : 0);
      _selectedMethod = _methods.isEmpty ? null : 0;
      _loading = false;
      _error = null;
    });
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
      // 合并下单+支付：下单时带支付方式 key，后端直接返回 payment_qr_code，省一个来回
      final order = await OrderService.instance.create(
        packageId: plan.id,
        paymentMethodKey: method.payType,
      );
      final orderId = (order['id'] as num?)?.toInt() ?? 0;
      final orderNo = order['order_no']?.toString() ?? '';
      if (orderId == 0) throw Exception(AppStrings.t('order_failed'));

      // 开通并刷新（付款成功 / 免费订单直接开通 共用）
      Future<void> activate() async {
        if (!mounted) return;
        _toast(AppStrings.t('activated'));
        try {
          final nodes = await AccountService.instance.refreshAfterPurchase();
          if (mounted) {
            await context.read<ConnectionController>().applySubscriptionNodes(nodes);
          }
        } catch (_) {}
      }

      // 免费/全额抵扣订单：后端直接置 paid，无需二维码，直接开通
      if (order['status']?.toString() == 'paid') {
        await activate();
        return;
      }

      // 金额以后端订单为准：final_amount 含折扣，为 0/缺省则回退 amount，再回退套餐价
      final fa = (order['final_amount'] as num?)?.toDouble() ?? 0;
      final am = (order['amount'] as num?)?.toDouble() ?? 0;
      final orderAmount = fa > 0 ? fa : (am > 0 ? am : _amount);

      // 优先用下单响应里的二维码；为空再回退单独发起支付
      var qr = order['payment_qr_code']?.toString() ?? order['payment_url']?.toString() ?? '';
      var payOrderNo = orderNo;
      if (qr.isEmpty) {
        final pay = await OrderService.instance.pay(orderId: orderId, paymentMethodId: method.id);
        qr = pay.qrCode;
        if (pay.orderNo.isNotEmpty) payOrderNo = pay.orderNo;
      }
      if (qr.isEmpty) throw Exception(AppStrings.t('no_qrcode'));

      if (!mounted) return;
      final paid = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PaymentQrDialog(
          qrContent: qr,
          orderNo: payOrderNo,
          amount: orderAmount,
          methodName: method.name,
          onPaid: () {},
        ),
      );
      if (paid == true) await activate();
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

  /// 首次无缓存加载的占位骨架：静态灰块镜像真实布局（不做 shimmer 动画，低端机不掉帧）。
  Widget _buildSkeleton() {
    Widget block(double w, double h, {double r = 8}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(color: MFColors.card2, borderRadius: BorderRadius.circular(r)),
        );
    Widget planRow() => Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
          decoration: BoxDecoration(
              color: MFColors.card, borderRadius: BorderRadius.circular(16), border: Border.all(color: MFColors.line)),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                block(120, 15),
                const SizedBox(height: 8),
                block(180, 11),
              ]),
            ),
            const SizedBox(width: 12),
            block(54, 22),
          ]),
        );
    Widget methodRow() => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
              color: MFColors.card, borderRadius: BorderRadius.circular(15), border: Border.all(color: MFColors.line)),
          child: Row(children: [
            block(34, 34, r: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                block(90, 14),
                const SizedBox(height: 6),
                block(140, 10),
              ]),
            ),
          ]),
        );
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
      children: [
        block(140, 21),
        const SizedBox(height: 8),
        block(200, 12),
        const SizedBox(height: 18),
        planRow(),
        planRow(),
        planRow(),
        const SizedBox(height: 10),
        block(80, 13),
        const SizedBox(height: 12),
        methodRow(),
        methodRow(),
        const SizedBox(height: 20),
        block(double.infinity, 50, r: 14),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _loading
            ? _buildSkeleton()
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
                    if (_error != null)
                      SizedBox(
                        height: 320,
                        child: MFEmpty(
                          title: _error!,
                          icon: Icons.cloud_off_outlined,
                          actionLabel: AppStrings.t('retry'),
                          onAction: _load,
                        ),
                      )
                    else if (_plans.isEmpty)
                      SizedBox(
                        height: 320,
                        child: MFEmpty(title: AppStrings.t('no_plans')),
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
                              TextSpan(text: formatPrice(_amount),
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
            // 只显示价格；下单入口统一走底部「合计 + 立即支付」，避免双入口/漏选支付方式
            Text.rich(TextSpan(children: [
              TextSpan(text: '¥${formatPrice(p.price)}',
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      fontFamily: kNumFont,
                      color: selected ? MFColors.brandLight : MFColors.txt)),
              TextSpan(text: _periodLabel(p), style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
            ])),
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
