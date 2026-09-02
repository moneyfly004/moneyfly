import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/services/auth_service.dart';
import '../../l10n/app_strings.dart';
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
      _toast(AppStrings.t('input_account_pwd'));
      return;
    }
    setState(() => _loading = true);
    try {
      await AuthService.instance.login(_account.text, _password.text);
      if (mounted) context.read<SessionState>().setLoggedIn(true);
    } catch (e) {
      final msg = ApiClient.errorMsg(e);
      // 账号被禁用：后端登录返回 403「账户已被禁用…」——弹窗明确提示，
      // 而不是普通 toast（用户需要知道不是密码错、且无法自助解决）
      final m = msg.toLowerCase();
      if (msg.contains('禁用') ||
          msg.contains('禁止') ||
          m.contains('disabled') ||
          m.contains('banned')) {
        _showDisabledDialog(msg);
      } else {
        _toast(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showDisabledDialog(String msg) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
        title: Text(AppStrings.t('account_disabled_title'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(msg,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, color: MFColors.txt2, height: 1.7)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('ok_btn')),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.height < 820;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: compact ? 32 : 70),
              Center(
                child: Container(
                  width: compact ? 60 : 76,
                  height: compact ? 60 : 76,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: MFColors.brand.withValues(alpha: .35), blurRadius: 40, offset: const Offset(0, 16)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset('assets/moneyfly-logo.png', width: compact ? 60 : 76, height: compact ? 60 : 76),
                  ),
                ),
              ),
              SizedBox(height: compact ? 12 : 18),
              Center(
                child: Text(AppStrings.t('app_name'),
                    style: TextStyle(fontSize: compact ? 24 : 28, fontWeight: FontWeight.w700, letterSpacing: 1.6)),
              ),
              const SizedBox(height: 6),
               Center(
                child: Text(AppStrings.t('slogan'),
                    style: TextStyle(fontSize: 12.5, color: MFColors.txt3, letterSpacing: 3)),
              ),
              SizedBox(height: compact ? 24 : 44),
              _Field(
                label: AppStrings.t('account_label'),
                controller: _account,
                hint: AppStrings.t('account_hint'),
                action: TextInputAction.next,
                onSubmitted: (_) => FocusScope.of(context).nextFocus(),
              ),
              const SizedBox(height: 12),
              _Field(
                label: AppStrings.t('password_label'),
                controller: _password,
                hint: AppStrings.t('password_hint'),
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
                   Text(AppStrings.t('auto_login'), style: TextStyle(fontSize: 13, color: MFColors.txt2)),
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
              SizedBox(height: compact ? 10 : 16),
              MFPrimaryButton(label: AppStrings.t('login_button'), loading: _loading, onPressed: _loading ? null : _login),
              SizedBox(height: compact ? 16 : 26),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const RegisterPage())),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: AppStrings.t('no_account'), style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
                      TextSpan(text: AppStrings.t('register'), style: TextStyle(fontSize: 13.5, color: MFColors.brandLight, fontWeight: FontWeight.w600)),
                    ])),
                  ),
                  Container(width: 1, height: 12, margin: const EdgeInsets.symmetric(horizontal: 18), color: MFColors.line2),
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ForgotPasswordPage())),
                    child: Text(AppStrings.t('forgot_password'), style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
                  ),
                ],
              ),
              SizedBox(height: compact ? 16 : 40),
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
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 15),
          cursorColor: MFColors.brand,
          textInputAction: action,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(hintText: hint, suffixIcon: trailing),
        ),
      ],
    );
  }
}
