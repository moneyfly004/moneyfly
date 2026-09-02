import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/password_policy.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// 修改密码（登录态，需旧密码 + 新密码）
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _old = TextEditingController();
  final _newPwd = TextEditingController();
  final _confirm = TextEditingController();
  final bool _obscure = true;
  bool _loading = false;

  @override
  void dispose() {
    _old.dispose();
    _newPwd.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_old.text.isEmpty) return _toast(AppStrings.t('pwd_old_required'));
    // 与后端同规则校验（长度≥8 + 四类字符至少三种），避免提交后服务端报强度不足
    final pwdErr = PasswordPolicy.errorFor(_newPwd.text);
    if (pwdErr != null) return _toast(pwdErr);
    if (_newPwd.text != _confirm.text) return _toast(AppStrings.t('pwd_mismatch'));
    setState(() => _loading = true);
    try {
      await AuthService.instance.changePassword(
        oldPassword: _old.text,
        newPassword: _newPwd.text,
      );
      _toast(AppStrings.t('pwd_changed'));
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
        title: Text(AppStrings.t('change_pwd')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
               Text('🔒 ${AppStrings.t('pwd_change_tip')}',
                  style: TextStyle(fontSize: 11.5, color: MFColors.txt3, height: 1.7)),
              const SizedBox(height: 22),
              _field(AppStrings.t('cur_pwd'), _old, hint: AppStrings.t('cur_pwd_hint'), obscure: _obscure),
              const SizedBox(height: 12),
              _field(AppStrings.t('new_pwd'), _newPwd, hint: AppStrings.t('new_pwd_hint'), obscure: _obscure),
              const SizedBox(height: 12),
              _field(AppStrings.t('confirm_pwd'), _confirm, hint: AppStrings.t('confirm_pwd_hint'), obscure: _obscure),
              const SizedBox(height: 26),
              MFPrimaryButton(label: AppStrings.t('save_pwd'), loading: _loading, onPressed: _loading ? null : _submit),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController c, {required String hint, required bool obscure}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 7),
          child: Text(label, style:  TextStyle(fontSize: 12.5, color: MFColors.txt2, fontWeight: FontWeight.w500)),
        ),
        TextField(
          controller: c,
          obscureText: obscure,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 15),
          cursorColor: MFColors.brand,
          decoration: InputDecoration(hintText: hint),
        ),
      ],
    );
  }
}
