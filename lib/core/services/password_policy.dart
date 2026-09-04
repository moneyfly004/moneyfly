import '../../l10n/app_strings.dart';

/// 邮箱格式校验（与后端一致的宽松正则，拦截明显输入错误）
bool looksLikeEmail(String s) =>
    RegExp(r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$').hasMatch(s.trim());

/// 密码强度策略 —— 与后端完全一致，避免「客户端只查长度、服务端返回强度不足」的落差：
///
/// 1. 长度 ≥ 8（后端 min_password_length 可配置，默认 8，客户端按默认值校验）；
/// 2. 大小写字母 / 数字 / 特殊字符 至少包含三种（后端
///    `!@#$%^&*()_+-=[]{}|;:,.<>?`）。
class PasswordPolicy {
  PasswordPolicy._();

  /// 合法特殊字符集合（与后端 auth.ValidatePasswordStrength 一致）
  static const specials = '!@#\$%^&*()_+-=[]{}|;:,.<>?';

  /// 校验新密码：合法返回 null，否则返回可直接展示的错误文案
  static String? errorFor(String pwd) {
    if (pwd.length < 8) return AppStrings.t('pwd_short');
    var hasUpper = false;
    var hasLower = false;
    var hasDigit = false;
    var hasSpecial = false;
    for (final c in pwd.runes) {
      final ch = String.fromCharCode(c);
      if (ch.codeUnitAt(0) >= 0x41 && ch.codeUnitAt(0) <= 0x5A) {
        hasUpper = true;
      } else if (ch.codeUnitAt(0) >= 0x61 && ch.codeUnitAt(0) <= 0x7A) {
        hasLower = true;
      } else if (ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39) {
        hasDigit = true;
      } else if (specials.contains(ch)) {
        hasSpecial = true;
      }
    }
    var kinds = 0;
    if (hasUpper) kinds++;
    if (hasLower) kinds++;
    if (hasDigit) kinds++;
    if (hasSpecial) kinds++;
    if (kinds < 3) return AppStrings.t('pwd_weak');
    return null;
  }

  /// 输入框提示文案（长度 + 组合要求）
  static String get hint => AppStrings.t('new_pwd_hint');
}
