import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../../core/api/api_client.dart';
import '../../core/api/endpoints.dart';
import '../../theme/app_theme.dart';

/// 注册页（设计稿 07）：邮箱 + 验证码（60s 倒计时）+ 用户名 + 密码 + 邀请码
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _invite = TextEditingController();

  bool _obscure = true;
  bool _agreed = true;
  bool _sending = false;
  bool _codeSent = false;
  int _countdown = 0;
  Timer? _timer;
  bool _loading = false;

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in [_email, _code, _username, _password, _confirm, _invite]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      _toast(AppStrings.t('email_invalid'));
      return;
    }
    setState(() => _sending = true);
    try {
      await ApiClient.instance.post(Endpoints.sendCode, data: {'type': 'email', 'email': email});
      if (!mounted) return; // 等待期间页面已退出
      _toast('验证码已发送到邮箱，5 分钟内有效');
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

  Future<void> _register() async {
    if (_username.text.trim().length < 4) return _toast(AppStrings.t('username_short'));
    if (_password.text.length < 8) return _toast(AppStrings.t('pwd_short'));
    if (_password.text != _confirm.text) return _toast(AppStrings.t('pwd_mismatch'));
    if (!_agreed) return _toast(AppStrings.t('agree_required'));
    setState(() => _loading = true);
    try {
      await ApiClient.instance.post(Endpoints.register, data: {
        'username': _username.text.trim(),
        'email': _email.text.trim(),
        'password': _password.text,
        'verification_code': _code.text.trim(),
        if (_invite.text.trim().isNotEmpty) 'invite_code': _invite.text.trim(),
      });
      _toast(AppStrings.t('registered'));
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
        title: Text(AppStrings.t('register_title')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('login_title'), style: TextStyle(color: MFColors.brandLight, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
               Text(AppStrings.t('join_moneyfly'),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: MFColors.txt)),
              const SizedBox(height: 4),
               Text(AppStrings.t('join_tip'),
                  style: TextStyle(fontSize: 11.5, color: MFColors.txt3)),
              const SizedBox(height: 24),
              _field(AppStrings.t('email_label'), _email, hint: AppStrings.t('email_hint')),
              const SizedBox(height: 12),
              _field('验证码', _code,
                  hint: AppStrings.t('code_hint'),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
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
                                style:  TextStyle(fontSize: 12, color: MFColors.txt3, fontFamily: kNumFont)),
                          )
                        : GestureDetector(
                            onTap: _sending ? null : _sendCode,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                gradient: MFColors.brandGradient,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(_sending ? AppStrings.t('sending') : AppStrings.t('send_code'),
                                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                            ),
                          ),
                  )),
              if (_codeSent) ...[
                const SizedBox(height: 6),
                Text(AppStrings.t('code_sent'),
                    style: TextStyle(fontSize: 10.5, color: MFColors.green, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 12),
              _field(AppStrings.t('username_label'), _username, hint: AppStrings.t('username_hint')),
              const SizedBox(height: 12),
              _field(AppStrings.t('password_label'), _password, hint: AppStrings.t('new_pwd_hint'), obscure: _obscure),
              const SizedBox(height: 12),
              _field(AppStrings.t('confirm_pwd'), _confirm, hint: AppStrings.t('confirm_pwd_hint'), obscure: _obscure),
              const SizedBox(height: 12),
              _field(AppStrings.t('invite_label'), _invite, hint: AppStrings.t('invite_hint')),
              const SizedBox(height: 14),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => setState(() => _agreed = !_agreed),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        gradient: _agreed ? MFColors.brandGradient : null,
                        color: _agreed ? null : MFColors.card,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _agreed ? Colors.transparent : MFColors.line2),
                      ),
                      child: _agreed
                          ? const Icon(Icons.check, size: 12, color: Colors.white)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 9),
                   Expanded(
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: '我已阅读并同意 ', style: TextStyle(fontSize: 11.5, color: MFColors.txt2)),
                      TextSpan(text: '《用户协议》', style: TextStyle(fontSize: 11.5, color: MFColors.brandLight, fontWeight: FontWeight.w600)),
                      TextSpan(text: ' 与 ', style: TextStyle(fontSize: 11.5, color: MFColors.txt2)),
                      TextSpan(text: '《隐私政策》', style: TextStyle(fontSize: 11.5, color: MFColors.brandLight, fontWeight: FontWeight.w600)),
                    ])),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              MFPrimaryButton(label: AppStrings.t('register_btn'), loading: _loading, onPressed: _loading ? null : _register),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController c,
      {required String hint, bool obscure = false, Widget? suffix,
      List<TextInputFormatter>? inputFormatters}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 7),
          child: Text(label, style:  TextStyle(fontSize: 12.5, color: MFColors.txt2, fontWeight: FontWeight.w500)),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: c,
                obscureText: obscure,
                style:  TextStyle(color: MFColors.txt, fontSize: 15),
                inputFormatters: inputFormatters,
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
