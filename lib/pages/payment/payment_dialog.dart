import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api/api_client.dart';
import '../../core/services/order_service.dart';
import '../../theme/app_theme.dart';

/// 支付二维码弹窗（设计稿 05）：渲染二维码 + 真实轮询订单状态
class PaymentQrDialog extends StatefulWidget {
  const PaymentQrDialog({
    super.key,
    required this.qrContent,
    required this.orderNo,
    required this.amount,
    required this.methodName,
    this.onPaid,
  });

  final String qrContent;
  final String orderNo;
  final double amount;
  final String methodName;
  final VoidCallback? onPaid;

  @override
  State<PaymentQrDialog> createState() => _PaymentQrDialogState();
}

class _PaymentQrDialogState extends State<PaymentQrDialog> {
  int _elapsed = 0;
  bool _zoom = false;
  bool _polling = true;
  String? _pollError;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 轮询：2.5s 一次，最长 15 分钟；paid → 回调并关闭
  void _startPolling() {
    _timer = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
      if (!_polling || !mounted) return;
      setState(() => _elapsed += 3);
      if (_elapsed >= 900) {
        _timer?.cancel();
        setState(() => _polling = false);
        return;
      }
      try {
        final s = await OrderService.instance.status(widget.orderNo);
        if (!mounted) return;
        if (s.isPaid) {
          _timer?.cancel();
          setState(() => _polling = false);
          widget.onPaid?.call();
          Navigator.of(context).pop(true);
        } else if (s.status == 'cancelled' || s.status == 'expired') {
          _timer?.cancel();
          setState(() {
            _polling = false;
            _pollError = '订单已${s.status == 'cancelled' ? '取消' : '过期'}';
          });
        }
      } catch (e) {
        if (mounted) setState(() => _pollError = ApiClient.errorMsg(e));
      }
    });
  }

  String get _clock {
    final m = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsed % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 26),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: const LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Color(0xFF171E2E), Color(0xFF10141F)]),
          border: Border.all(color: MFColors.line2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('请使用${widget.methodName}扫码支付', style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text('${widget.methodName.toUpperCase()} · SECURE PAYMENT',
                style:  TextStyle(fontSize: 10, color: MFColors.txt3, letterSpacing: 1.4)),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => setState(() => _zoom = !_zoom),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _zoom ? 250 : 196,
                height: _zoom ? 250 : 196,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(17),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .5), blurRadius: 30)],
                ),
                child: QrImageView(
                  data: widget.qrContent,
                  version: QrVersions.auto,
                  size: _zoom ? 228 : 174,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF111111)),
                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF111111)),
                ),
              ),
            ),
            const SizedBox(height: 6),
             Text('点按二维码可放大', style: TextStyle(fontSize: 10, color: MFColors.txt3)),
            const SizedBox(height: 12),
            Text.rich(TextSpan(children: [
               TextSpan(text: '¥', style: TextStyle(fontSize: 15, color: MFColors.txt2)),
              TextSpan(text: widget.amount.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w700, fontFamily: kNumFont)),
            ])),
            const SizedBox(height: 5),
            GestureDetector(
              onTap: () {
                // 剪贴板无需等待，直接提示
                Clipboard.setData(ClipboardData(text: widget.orderNo));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('订单号已复制'), duration: Duration(seconds: 1)),
                );
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('订单号 ${widget.orderNo}',
                      style:  TextStyle(fontSize: 11, color: MFColors.txt3, fontFamily: kNumFont, letterSpacing: .5)),
                  const SizedBox(width: 5),
                   Icon(Icons.copy, size: 12, color: MFColors.txt3),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (_polling)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 13, height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2, color: MFColors.brandLight)),
                  const SizedBox(width: 8),
                  Text('等待支付 $_clock，支付成功后自动开通套餐…',
                      style:  TextStyle(fontSize: 12, color: MFColors.txt2)),
                ],
              )
            else
              Text(_pollError ?? '已停止轮询',
                  style: TextStyle(fontSize: 12, color: _pollError != null ? MFColors.red : MFColors.txt3)),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: MFColors.txt2,
                      side:  BorderSide(color: MFColors.line2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      // 手动立即查一次：重置计时与轮询状态，避免超时后无法再查
                      _timer?.cancel();
                      _elapsed = 0;
                      _polling = true;
                      _pollError = null;
                      _startPolling();
                    },
                    child: Container(
                      height: 50,
                      decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(14)),
                      alignment: Alignment.center,
                      child: const Text('我已支付', style: TextStyle(fontSize: 15, color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
