import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/services/auth_service.dart';
import '../../main.dart';
import '../../theme/app_theme.dart';
import 'forgot_password_page.dart';
import 'register_page.dart';

/// 登录页（设计稿 01）
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const _autoLoginKey = 'moneyfly_auto_login';

  final _account = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _autoLogin = true;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // 恢复「自动登录」开关状态（与 SessionState.restore 联动）
    SharedPreferences.getInstance()
        .then((p) => p.getBool(_autoLoginKey))
        .then((v) {
      if (mounted && v != null) setState(() => _autoLogin = v);
    });
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 自动登录开关：关闭后下次启动不自动恢复登录态
  static Future<void> setAutoLogin(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_autoLoginKey, v);
  }

  Future<void> _login() async {
    if (_account.text.trim().isEmpty || _password.text.isEmpty) {
      _toast('请输入账号和密码');
      return;
    }
    setState(() => _loading = true);
    try {
      await AuthService.instance.login(_account.text, _password.text);
      if (mounted) context.read<SessionState>().setLoggedIn(true);
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
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 70),
              Center(
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: MFColors.brand.withValues(alpha: .35), blurRadius: 40, offset: const Offset(0, 16)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset('assets/moneyfly-logo.png', width: 76, height: 76),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Center(
                child: Text('MoneyFly',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 1.6)),
              ),
              const SizedBox(height: 6),
               Center(
                child: Text('极速 · 稳定 · 全球畅连',
                    style: TextStyle(fontSize: 12.5, color: MFColors.txt3, letterSpacing: 3)),
              ),
              const SizedBox(height: 44),
              _Field(
                label: '账号 / 邮箱',
                controller: _account,
                hint: '请输入账号或邮箱',
                action: TextInputAction.next,
                onSubmitted: (_) => FocusScope.of(context).nextFocus(),
              ),
              const SizedBox(height: 12),
              _Field(
                label: '密码',
                controller: _password,
                hint: '请输入密码',
                obscure: _obscure,
                action: TextInputAction.done,
                onSubmitted: (_) => _loading ? null : _login(),
                trailing: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      size: 20, color: MFColors.txt3),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                   Text('自动登录', style: TextStyle(fontSize: 13, color: MFColors.txt2)),
                  const Spacer(),
                  Switch(
                    value: _autoLogin,
                    onChanged: (v) {
                      setState(() => _autoLogin = v);
                      setAutoLogin(v);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              MFPrimaryButton(label: '登 录', loading: _loading, onPressed: _loading ? null : _login),
              const SizedBox(height: 26),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const RegisterPage())),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: '还没有账号？', style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
                      TextSpan(text: '注册', style: TextStyle(fontSize: 13.5, color: MFColors.brandLight, fontWeight: FontWeight.w600)),
                    ])),
                  ),
                  Container(width: 1, height: 12, margin: const EdgeInsets.symmetric(horizontal: 18), color: MFColors.line2),
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ForgotPasswordPage())),
                    child:  Text('忘记密码', style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
                  ),
                ],
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.trailing,
    this.action,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final Widget? trailing;
  final TextInputAction? action;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 7),
          child: Text(label, style:  TextStyle(fontSize: 12.5, color: MFColors.txt2, fontWeight: FontWeight.w500)),
        ),
        TextField(
          controller: controller,
          obscureText: obscure,
          style:  TextStyle(color: MFColors.txt, fontSize: 15),
          textInputAction: action,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(hintText: hint, suffixIcon: trailing),
        ),
      ],
    );
  }
}
