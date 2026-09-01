import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/endpoints.dart';
import '../../theme/app_theme.dart';

/// 找回密码（设计稿 08）：邮箱验证码两步重置
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();

  final bool _obscure = true;
  bool _sending = false;
  bool _codeSent = false;
  int _countdown = 0;
  Timer? _timer;
  bool _loading = false;

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in [_email, _code, _newPassword, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) return _toast('请先输入正确的注册邮箱');
    setState(() => _sending = true);
    try {
      await ApiClient.instance.post(Endpoints.forgotPassword, data: {'email': email});
      if (!mounted) return; // 等待期间页面已退出
      _toast('重置验证码已发送到邮箱');
      setState(() {
        _codeSent = true;
        _countdown = 60;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel(); // 页面销毁后停止倒计时
        if (_countdown <= 1) {
          t.cancel();
          setState(() => _countdown = 0);
        } else {
          setState(() => _countdown--);
        }
      });
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _reset() async {
    if (_newPassword.text.length < 8) return _toast('新密码至少 8 位');
    if (_newPassword.text != _confirm.text) return _toast('两次输入的新密码不一致');
    setState(() => _loading = true);
    try {
      await ApiClient.instance.post(Endpoints.resetPassword, data: {
        'email': _email.text.trim(),
        'verification_code': _code.text.trim(),
        'new_password': _newPassword.text,
      });
      _toast('密码已重置，请使用新密码登录');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
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
        title: const Text('找回密码'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('登录', style: TextStyle(color: MFColors.brandLight, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 步骤条
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  _Step(done: true, no: '✓', label: '验证身份'),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: SizedBox(width: 26, height: 1, child: ColoredBox(color: MFColors.line2)),
                  ),
                  _Step(done: false, no: '2', label: '设置新密码'),
                ],
              ),
              const SizedBox(height: 26),
              _field('邮箱', _email, hint: '请输入注册邮箱'),
              const SizedBox(height: 12),
              _field('验证码', _code,
                  hint: '6 位验证码',
                  suffix: SizedBox(
                    width: 104,
                    height: 48,
                    child: _countdown > 0
                        ? Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: MFColors.card,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: MFColors.line2),
                            ),
                            child: Text('${_countdown}s 后重发',
                                style: const TextStyle(fontSize: 12, color: MFColors.txt3, fontFamily: kNumFont)),
                          )
                        : GestureDetector(
                            onTap: _sending ? null : _sendCode,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(gradient: MFColors.brandGradient, borderRadius: BorderRadius.circular(12)),
                              child: Text(_sending ? '发送中…' : '发送验证码',
                                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                            ),
                          ),
                  )),
              if (_codeSent) ...[
                const SizedBox(height: 6),
                const Text('✓ 身份验证通过', style: TextStyle(fontSize: 10.5, color: MFColors.green, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 12),
              _field('新密码', _newPassword, hint: '至少 8 位，含字母和数字', obscure: _obscure),
              const SizedBox(height: 12),
              _field('确认新密码', _confirm, hint: '再次输入新密码', obscure: _obscure),
              const SizedBox(height: 14),
              const Text('🔒 验证码将发送到注册邮箱，5 分钟内有效；重置成功后请使用新密码登录。',
                  style: TextStyle(fontSize: 11, color: MFColors.txt3, height: 1.7)),
              const SizedBox(height: 22),
              MFPrimaryButton(label: '重置密码', loading: _loading, onPressed: _loading ? null : _reset),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController c,
      {required String hint, bool obscure = false, Widget? suffix}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 7),
          child: Text(label, style: const TextStyle(fontSize: 12.5, color: MFColors.txt2, fontWeight: FontWeight.w500)),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: c,
                obscureText: obscure,
                style: const TextStyle(color: MFColors.txt, fontSize: 15),
                decoration: InputDecoration(hintText: hint),
              ),
            ),
            if (suffix != null) ...[const SizedBox(width: 10), suffix],
          ],
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.done, required this.no, required this.label});
  final bool done;
  final String no;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = done ? MFColors.green : MFColors.brandLight;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: done ? MFColors.green.withValues(alpha: .18) : MFColors.brand.withValues(alpha: .18),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(no, style: TextStyle(fontSize: 10.5, color: color, fontFamily: kNumFont, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
