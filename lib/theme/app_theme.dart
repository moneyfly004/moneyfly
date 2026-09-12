import 'package:flutter/material.dart';

import 'theme_controller.dart';

/// 主题色（accent）定义：一套品牌色 = 主色 + 亮色 + 深色，驱动按钮/高亮/渐变。
class MFAccent {
  const MFAccent(this.brand, this.brandLight, this.brandDeep);
  final Color brand;
  final Color brandLight;
  final Color brandDeep;
}

/// 6 套可选主题色（key → 配色）
const Map<String, MFAccent> _mfAccents = {
  'ocean': MFAccent(Color(0xFF455FE9), Color(0xFF6C7BFF), Color(0xFF7A5CFF)),
  'emerald': MFAccent(Color(0xFF10B981), Color(0xFF34D399), Color(0xFF059669)),
  'violet': MFAccent(Color(0xFF8B5CF6), Color(0xFFA78BFA), Color(0xFF6D28D9)),
  'coral': MFAccent(Color(0xFFF97316), Color(0xFFFB923C), Color(0xFFC2410C)),
  'rose': MFAccent(Color(0xFFEC4899), Color(0xFFF472B6), Color(0xFFBE185D)),
  'teal': MFAccent(Color(0xFF14B8A6), Color(0xFF2DD4BF), Color(0xFF0F766E)),
};

/// 全部主题色 key（设置页色板遍历顺序）
const List<String> mfAccentKeys = [
  'ocean', 'emerald', 'violet', 'coral', 'rose', 'teal',
];

/// 主题色 key → 展示名 i18n key
const Map<String, String> mfAccentLabels = {
  'ocean': 'theme_ocean',
  'emerald': 'theme_emerald',
  'violet': 'theme_violet',
  'coral': 'theme_coral',
  'rose': 'theme_rose',
  'teal': 'theme_teal',
};

/// 取某主题色的主色（设置页色板用）
Color mfAccentBrand(String key) =>
    _mfAccents[key]?.brand ?? _mfAccents['ocean']!.brand;

/// MoneyFly 设计令牌（与 design/ 设计稿一致）
/// 颜色为动态 getter：随 ThemeController.isLight 在暗色/浅色间切换，
/// 页面里 `MFColors.xxx` 的写法不用改，切主题自动生效。
class MFColors {
  MFColors._();

  static bool get _light => ThemeController.instance.isLight;

  static MFAccent get _accent =>
      _mfAccents[ThemeController.instance.accent] ?? _mfAccents['ocean']!;

  // 品牌（随所选主题色动态变化）
  static Color get brand => _accent.brand;
  static Color get brandLight => _accent.brandLight;
  static Color get brandDeep => _accent.brandDeep;
  static LinearGradient get brandGradient => LinearGradient(
        colors: [brand, brandLight, brandDeep],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  // 背景（暗色用「中灰黑」而非近黑，层次更清晰、文字不发闷）
  static Color get bg => _light ? const Color(0xFFF5F7FB) : const Color(0xFF15181D);
  static Color get bg2 => _light ? const Color(0xFFFFFFFF) : const Color(0xFF1A1E24);
  static Color get card => _light ? const Color(0xFFFFFFFF) : const Color(0xFF1E2229);
  static Color get card2 => _light ? const Color(0xFFF0F3FA) : const Color(0xFF272C35);

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
  final bg = dark ? const Color(0xFF15181D) : const Color(0xFFF5F7FB);
  final card = dark ? const Color(0xFF1E2229) : const Color(0xFFFFFFFF);
  final card2 = dark ? const Color(0xFF272C35) : const Color(0xFFF0F3FA);
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
