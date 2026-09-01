import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../theme/app_theme.dart';
import '../payment/payment_dialog.dart';

/// 我的订单：列表 + 待支付订单可继续支付/取消
class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key});

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  List<OrderItem> _orders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final list = await OrderService.instance.list();
      if (mounted) setState(() => _orders = list);
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _payOrder(OrderItem o) async {
    try {
      // 先确认订单仍是待支付
      final st = await OrderService.instance.status(o.orderNo);
      if (!mounted) return;
      if (st.isPaid) {
        _toast('该订单已支付');
        return;
      }
      if (st.status != 'pending') {
        _toast('订单状态：${st.status}，无法继续支付');
        return;
      }
      // 用当前启用的第一个支付方式（跟随官网后台设置）重新发起
      final methods = await PaymentService.instance.methods();
      if (!mounted) return;
      if (methods.isEmpty) {
        _toast('暂无可用的支付方式');
        return;
      }
      final pay = await OrderService.instance.pay(orderId: o.id, paymentMethodId: methods.first.id);
      if (pay.qrCode.isEmpty) {
        _toast('未获取到支付二维码，请稍后重试');
        return;
      }
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PaymentQrDialog(
          qrContent: pay.qrCode,
          orderNo: pay.orderNo.isEmpty ? o.orderNo : pay.orderNo,
          amount: o.finalAmount > 0 ? o.finalAmount : o.amount,
          methodName: methods.first.name,
          onPaid: () {},
        ),
      );
      await _load();
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  Future<void> _cancelOrder(OrderItem o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: const Text('取消订单', style: TextStyle(fontSize: 16)),
        content: const Text('确定取消这笔待支付订单吗？', style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('再想想')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消订单', style: TextStyle(color: MFColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await OrderService.instance.cancel(o.orderNo);
      await _load();
      if (mounted) _toast('订单已取消');
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
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
        title: const Text('我的订单'),
        actions: [TextButton(onPressed: _load, child: const Text('刷新', style: TextStyle(color: MFColors.brandLight)))],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: MFColors.brand))
            : _orders.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('暂无订单', style: TextStyle(fontSize: 14, color: MFColors.txt3)),
                        const SizedBox(height: 8),
                        const Text('购买套餐后订单会显示在这里', style: TextStyle(fontSize: 12, color: MFColors.txt3)),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                    itemCount: _orders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _buildOrderCard(_orders[i]),
                  ),
      ),
    );
  }

  Color _statusColor(String status) => switch (status) {
        'paid' => MFColors.green,
        'pending' => MFColors.amber,
        _ => MFColors.txt3,
      };

  Widget _buildOrderCard(OrderItem o) {
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
              Expanded(
                child: Text(o.packageName ?? '订单 ${o.type}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor(o.status).withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _statusColor(o.status).withValues(alpha: .3)),
                ),
                child: Text(o.statusLabel,
                    style: TextStyle(fontSize: 10.5, color: _statusColor(o.status), fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('¥${(o.finalAmount > 0 ? o.finalAmount : o.amount).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, fontFamily: kNumFont)),
              const Spacer(),
              Text(o.orderNo,
                  style: const TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont)),
            ],
          ),
          if (o.createdAt.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('下单时间 ${o.createdAt}', style: const TextStyle(fontSize: 10.5, color: MFColors.txt3)),
          ],
          if (o.status == 'pending') ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Spacer(),
                GestureDetector(
                  onTap: () => _cancelOrder(o),
                  child: Container(
                    height: 32, padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                        color: MFColors.red.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: MFColors.red.withValues(alpha: .3))),
                    alignment: Alignment.center,
                    child: const Text('取消订单', style: TextStyle(fontSize: 11.5, color: MFColors.red, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => _payOrder(o),
                  child: Container(
                    height: 32, padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(10)),
                    alignment: Alignment.center,
                    child: const Text('继续支付', style: TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
