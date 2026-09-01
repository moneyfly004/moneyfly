import 'package:flutter/material.dart';

import 'theme_controller.dart';

/// MoneyFly 设计令牌（与 design/ 设计稿一致）
/// 颜色为动态 getter：随 ThemeController.isLight 在暗色/浅色间切换，
/// 页面里 `MFColors.xxx` 的写法不用改，切主题自动生效。
class MFColors {
  MFColors._();

  static bool get _light => ThemeController.instance.isLight;

  // 品牌（深浅色共用）
  static const brand = Color(0xFF455FE9);
  static const brandLight = Color(0xFF6C7BFF);
  static const brandDeep = Color(0xFF7A5CFF);
  static const brandGradient = LinearGradient(
    colors: [brand, brandLight, brandDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // 背景
  static Color get bg => _light ? const Color(0xFFF5F7FB) : const Color(0xFF0B0E14);
  static Color get bg2 => _light ? const Color(0xFFFFFFFF) : const Color(0xFF0E121B);
  static Color get card => _light ? const Color(0xFFFFFFFF) : const Color(0xFF141926);
  static Color get card2 => _light ? const Color(0xFFF0F3FA) : const Color(0xFF1A2132);

  // 线条
  static Color get line => _light ? const Color(0x141A2B4A) : const Color(0x12FFFFFF);
  static Color get line2 => _light ? const Color(0x241A2B4A) : const Color(0x1FFFFFFF);

  // 文本
  static Color get txt => _light ? const Color(0xFF1A2233) : const Color(0xFFF5F7FF);
  static Color get txt2 => _light ? const Color(0xFF4A5568) : const Color(0xFF9AA3B5);
  static Color get txt3 => _light ? const Color(0xFF8A94A6) : const Color(0xFF5E6778);

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
  final scheme = dark
      ? ColorScheme.dark(
          primary: MFColors.brand,
          secondary: MFColors.brandLight,
          surface: MFColors.card,
          onSurface: MFColors.txt,
          error: MFColors.red,
        )
      : ColorScheme.light(
          primary: MFColors.brand,
          secondary: MFColors.brandLight,
          surface: MFColors.card,
          onSurface: MFColors.txt,
          error: MFColors.red,
        );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: MFColors.bg,
    brightness: brightness,
    fontFamily: 'PingFang SC',
    textTheme: TextTheme(
      titleLarge: TextStyle(color: MFColors.txt, fontWeight: FontWeight.w700, fontSize: 20),
      bodyMedium: TextStyle(color: MFColors.txt, fontSize: 14),
      bodySmall: TextStyle(color: MFColors.txt2, fontSize: 12),
      labelMedium: TextStyle(color: MFColors.txt2, fontSize: 12.5, fontWeight: FontWeight.w500),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: MFColors.bg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: MFColors.txt, fontSize: 18, fontWeight: FontWeight.w700),
      iconTheme: IconThemeData(color: MFColors.txt),
    ),
    cardTheme: CardThemeData(
      color: MFColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: MFColors.line),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? MFColors.brand : const Color(0xFF2A3242),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: MFColors.card,
      hintStyle: TextStyle(color: MFColors.txt3, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: MFColors.line2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: MFColors.line2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: MFColors.brand, width: 1.4),
      ),
    ),
    dividerTheme: DividerThemeData(color: MFColors.line, thickness: 1, space: 1),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: MFColors.bg,
      selectedItemColor: MFColors.brandLight,
      unselectedItemColor: MFColors.txt3,
      type: BottomNavigationBarType.fixed,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: MFColors.card2,
      contentTextStyle: TextStyle(color: MFColors.txt, fontSize: 13),
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
            BoxShadow(color: MFColors.brand.withValues(alpha: .35), blurRadius: 24, offset: const Offset(0, 10)),
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
