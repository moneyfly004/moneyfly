import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// MoneyFly 统一输入框样式（设置内所有输入统一：填充背景、12 圆角、
/// 边框线、聚焦品牌色、无重叠塌陷问题）。
///
/// 用法：TextField(decoration: mfInput(hint: '...', helper: '...'))
InputDecoration mfInput({String? hint, String? helper}) {
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    hintText: hint,
    helperText: helper,
    filled: true,
    fillColor: MFColors.card,
    isDense: true,
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    hintStyle: TextStyle(fontSize: 12.5, color: MFColors.txt3),
    helperStyle: TextStyle(fontSize: 10.5, color: MFColors.txt3),
    errorStyle: TextStyle(fontSize: 11, color: MFColors.red),
    enabledBorder: border(MFColors.line),
    focusedBorder: border(MFColors.brand, 1.4),
    disabledBorder: border(MFColors.line),
  );
}
