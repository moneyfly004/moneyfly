import 'package:flutter/material.dart';

import 'theme_controller.dart';

/// 完整主题：一套暗色背景（bg/card/card2）+ 品牌色（brand/brandLight/brandDeep）。
/// 浅色模式统一用浅色背景，仅品牌色随主题变化。
class MFTheme {
  const MFTheme({
    required this.darkBg,
    required this.darkBg2,
    required this.darkCard,
    required this.darkCard2,
    required this.brand,
    required this.brandLight,
    required this.brandDeep,
  });
  final Color darkBg;
  final Color darkBg2;
  final Color darkCard;
  final Color darkCard2;
  final Color brand;
  final Color brandLight;
  final Color brandDeep;
}

/// 6 套完整主题（key → 配色）
const Map<String, MFTheme> _mfThemes = {
  'ocean': MFTheme(
      darkBg: Color(0xFF0E1420), darkBg2: Color(0xFF121826),
      darkCard: Color(0xFF182032), darkCard2: Color(0xFF222C40),
      brand: Color(0xFF455FE9), brandLight: Color(0xFF6C7BFF), brandDeep: Color(0xFF7A5CFF)),
  'midnight': MFTheme(
      darkBg: Color(0xFF0A0B0E), darkBg2: Color(0xFF101216),
      darkCard: Color(0xFF15171C), darkCard2: Color(0xFF1F2229),
      brand: Color(0xFF6C7BFF), brandLight: Color(0xFF8B9BFF), brandDeep: Color(0xFF5A67D8)),
  'graphite': MFTheme(
      darkBg: Color(0xFF16181D), darkBg2: Color(0xFF1B1E24),
      darkCard: Color(0xFF20242B), darkCard2: Color(0xFF2A2F37),
      brand: Color(0xFF94A3B8), brandLight: Color(0xFFA8B3C2), brandDeep: Color(0xFF7C8798)),
  'emerald': MFTheme(
      darkBg: Color(0xFF0D1A15), darkBg2: Color(0xFF112019),
      darkCard: Color(0xFF172720), darkCard2: Color(0xFF22342B),
      brand: Color(0xFF10B981), brandLight: Color(0xFF34D399), brandDeep: Color(0xFF059669)),
  'violet': MFTheme(
      darkBg: Color(0xFF151022), darkBg2: Color(0xFF1A1428),
      darkCard: Color(0xFF1F1730), darkCard2: Color(0xFF2B2240),
      brand: Color(0xFF8B5CF6), brandLight: Color(0xFFA78BFA), brandDeep: Color(0xFF6D28D9)),
  'warm': MFTheme(
      darkBg: Color(0xFF1A140D), darkBg2: Color(0xFF201811),
      darkCard: Color(0xFF261D13), darkCard2: Color(0xFF332819),
      brand: Color(0xFFF97316), brandLight: Color(0xFFFB923C), brandDeep: Color(0xFFC2410C)),
};

/// 全部主题 key（设置页遍历顺序）
const List<String> mfThemeKeys = [
  'ocean', 'midnight', 'graphite', 'emerald', 'violet', 'warm',
];

/// 主题 key → 展示名 i18n key
const Map<String, String> mfThemeLabels = {
  'ocean': 'theme_ocean',
  'midnight': 'theme_midnight',
  'graphite': 'theme_graphite',
  'emerald': 'theme_emerald',
  'violet': 'theme_violet',
  'warm': 'theme_warm',
};

/// 取某主题（设置页色卡预览用）
MFTheme mfThemeOf(String key) => _mfThemes[key] ?? _mfThemes['ocean']!;

/// MoneyFly 设计令牌（与 design/ 设计稿一致）
/// 颜色为动态 getter：随 ThemeController.isLight 在暗色/浅色间切换，
/// 页面里 `MFColors.xxx` 的写法不用改，切主题自动生效。
class MFColors {
  MFColors._();

  static bool get _light => ThemeController.instance.isLight;

  static MFTheme get _theme =>
      _mfThemes[ThemeController.instance.themeStyle] ?? _mfThemes['ocean']!;

  // 品牌（随所选主题动态变化）
  static Color get brand => _theme.brand;
  static Color get brandLight => _theme.brandLight;
  static Color get brandDeep => _theme.brandDeep;
  static LinearGradient get brandGradient => LinearGradient(
        colors: [brand, brandLight, brandDeep],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  // 背景（暗色随主题；浅色统一浅色）
  static Color get bg => _light ? const Color(0xFFF5F7FB) : _theme.darkBg;
  static Color get bg2 => _light ? const Color(0xFFFFFFFF) : _theme.darkBg2;
  static Color get card => _light ? const Color(0xFFFFFFFF) : _theme.darkCard;
  static Color get card2 => _light ? const Color(0xFFF0F3FA) : _theme.darkCard2;

  // 线条
  static Color get line => _light ? const Color(0x141A2B4A) : const Color(0x14FFFFFF);
  static Color get line2 => _light ? const Color(0x241A2B4A) : const Color(0x20FFFFFF);

  // 文本
  static Color get txt => _light ? const Color(0xFF1A2233) : const Color(0xFFF7F8FA);
  static Color get txt2 => _light ? const Color(0xFF4A5568) : const Color(0xFFB7C0CD);
  static Color get txt3 => _light ? const Color(0xFF8A94A6) : const Color(0xFF99A3B5);

  // 语义
  static const green = Color(0xFF2EE6A8);
  static const greenDeep = Color(0xFF1FA97E); // 浅色模式下深一点的绿（可读性）
  static const amber = Color(0xFFFFB020);
  static const red = Color(0xFFFF5A5F);
}

/// 数字字体（Chakra Petch 在桌面端可用；移动端回退 monospace）
const kNumFont = 'Chakra Petch';

ThemeData buildMoneyFlyTheme({Brightness brightness = Brightness.dark}) {
  final dark = brightness == Brightness.dark;
  // 颜色必须跟 brightness 参数绑定，不能读 ThemeController.isLight。
  // 否则 MaterialApp 同时构建 light/dark 两套主题时，输入框底色与文字色会错位
  // （白底白字 / 黑底黑字），登录页等输入框不可读。
  final mfTheme = _mfThemes[ThemeController.instance.themeStyle] ?? _mfThemes['ocean']!;
  final bg = dark ? mfTheme.darkBg : const Color(0xFFF5F7FB);
  final card = dark ? mfTheme.darkCard : const Color(0xFFFFFFFF);
  final card2 = dark ? mfTheme.darkCard2 : const Color(0xFFF0F3FA);
  final txt = dark ? const Color(0xFFF7F8FA) : const Color(0xFF1A2233);
  final txt2 = dark ? const Color(0xFFB7C0CD) : const Color(0xFF4A5568);
  final txt3 = dark ? const Color(0xFF99A3B5) : const Color(0xFF8A94A6);
  final line = dark ? const Color(0x14FFFFFF) : const Color(0x141A2B4A);
  final line2 = dark ? const Color(0x20FFFFFF) : const Color(0x241A2B4A);

  final scheme = dark
      ? ColorScheme.dark(
          primary: MFColors.brand,
          secondary: MFColors.brandLight,
          surface: card,
          onSurface: txt,
          error: MFColors.red,
        )
      : ColorScheme.light(
          primary: MFColors.brand,
          secondary: MFColors.brandLight,
          surface: card,
          onSurface: txt,
          error: MFColors.red,
        );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    brightness: brightness,
    fontFamily: 'PingFang SC',
    textTheme: TextTheme(
      titleLarge: TextStyle(color: txt, fontWeight: FontWeight.w700, fontSize: 20),
      bodyMedium: TextStyle(color: txt, fontSize: 14),
      bodySmall: TextStyle(color: txt2, fontSize: 12),
      labelMedium: TextStyle(color: txt2, fontSize: 12.5, fontWeight: FontWeight.w500),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: txt, fontSize: 18, fontWeight: FontWeight.w700),
      iconTheme: IconThemeData(color: txt),
    ),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: line),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? MFColors.brand : Color(0xFF2A3242),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: card2,
      hintStyle: TextStyle(color: txt3, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: line2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: line2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: MFColors.brand, width: 1.4),
      ),
    ),
    dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: bg,
      selectedItemColor: MFColors.brandLight,
      unselectedItemColor: txt3,
      type: BottomNavigationBarType.fixed,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: card2,
      contentTextStyle: TextStyle(color: txt, fontSize: 13),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

/// 渐变主按钮
class MFPrimaryButton extends StatelessWidget {
  const MFPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.height = 54,
    this.loading = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final bool loading;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: MFColors.brandGradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(color: MFColors.brand.withValues(alpha: .35), blurRadius: 24, offset: Offset(0, 10)),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onPressed,
            child: Center(
              child: loading
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[icon!, const SizedBox(width: 8)],
                        Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 延迟色阶(全局唯一口径,列表/弹层/当前节点卡共用):
/// 离线→红;在线未测→txt3; <100ms 绿; <300ms 琥珀; 其余 红。
Color mfLatencyColor(int latencyMs, bool online) {
  if (!online) return MFColors.red;
  if (latencyMs < 0) return MFColors.txt3;
  if (latencyMs < 100) return MFColors.green;
  if (latencyMs < 300) return MFColors.amber;
  return MFColors.red;
}

/// 金额显示：去掉无意义的尾零。
/// 0.02 → "0.02"；200 → "200"；200.5 → "200.5"；0 → "0"。
/// 修复「0.02 元套餐被 toStringAsFixed(0) 显示成 0 元」的问题。
String formatPrice(double v) {
  var s = v.toStringAsFixed(2);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    s = s.replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

/// 新版提示红点（8px 圆形，用于 tab 图标角标 / 设置行提示）
class RedDot extends StatelessWidget {
  const RedDot({super.key, this.size = 8});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration:
            const BoxDecoration(color: MFColors.red, shape: BoxShape.circle),
      );
}
