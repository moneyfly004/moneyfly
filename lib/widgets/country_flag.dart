import 'package:flutter/material.dart';

import '../core/models/models.dart';

/// 国旗显示组件：内置国旗图片（assets/flags/），
/// 解决 Windows 上 emoji 国旗退化为「HK/TW」字母的问题；
/// 图片加载失败时回退 emoji。
class CountryFlag extends StatelessWidget {
  const CountryFlag(this.code, {super.key, this.size = 17, this.rounded = false});

  final String? code;
  final double size;
  final bool rounded;

  @override
  Widget build(BuildContext context) {
    final c = code?.toUpperCase();
    final emoji = ProxyNode.countryFlags[c] ?? '\u{1F310}';
    final hasAsset = c != null && ProxyNode.countryFlags.containsKey(c);
    Widget child = hasAsset
        ? Image.asset(
            'assets/flags/${c.toLowerCase()}.png',
            width: size,
            height: size * 0.72,
            fit: BoxFit.fill,
            errorBuilder: (_, _, _) =>
                Text(emoji, style: TextStyle(fontSize: size)),
          )
        : Text(emoji, style: TextStyle(fontSize: size));
    if (!rounded) return child;
    return ClipRRect(borderRadius: BorderRadius.circular(2.5), child: child);
  }
}
