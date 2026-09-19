import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// MoneyFly 统一输入框样式（设置/弹窗里的输入统一：填充背景、圆角、边框线、
/// 聚焦品牌色、错误态）。
///
/// 用法：`TextField(decoration: mfInput(hint: '...', errorText: '...'))`
///
/// **单一来源**：配色/圆角/字号令牌来自 `lib/theme/app_theme.dart`
/// （`kInputRadius` / `kInputHintFontSize` / `kInputPaddingDense`），与全局
/// `inputDecorationTheme` 完全一致。历史上这里自己写了一套（fill=card、圆角 12、
/// hint 12.5），而主题是另一套（fill=card2、圆角 14、hint 13）—— 同一种输入框在
/// 登录页和设置弹窗里长得不一样。现在只有「内边距更紧凑 + isDense」这一处差异，
/// 那是弹窗空间小、刻意保留的。
InputDecoration mfInput({
  String? hint,
  String? helper,
  String? errorText,
  Widget? suffixIcon,
  Widget? prefixIcon,
}) {
  OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(kInputRadius),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    hintText: hint,
    helperText: helper,
    errorText: errorText,
    suffixIcon: suffixIcon,
    prefixIcon: prefixIcon,
    filled: true,
    fillColor: MFColors.card2,
    isDense: true,
    contentPadding: kInputPaddingDense,
    hintStyle: TextStyle(fontSize: kInputHintFontSize, color: MFColors.txt3),
    helperStyle: TextStyle(fontSize: 10.5, color: MFColors.txt3),
    errorStyle: TextStyle(fontSize: 11, color: MFColors.red),
    errorMaxLines: 2,
    enabledBorder: border(MFColors.line),
    focusedBorder: border(MFColors.brand, 1.4),
    disabledBorder: border(MFColors.line),
    errorBorder: border(MFColors.red, 1.2),
    focusedErrorBorder: border(MFColors.red, 1.4),
  );
}
