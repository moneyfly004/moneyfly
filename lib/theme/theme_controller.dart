import 'package:flutter/material.dart';

import '../core/services/settings_store.dart';

/// 主题控制器：全局单例，随设置「主题」切换
/// MFColors 的颜色取值动态跟随 isLight，MaterialApp 随 mode 重建
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  bool isLight = false;
  ThemeMode mode = ThemeMode.dark;

  /// 设置页「主题」变更入口（light / dark / system）
  void setTheme(String theme) {
    mode = switch (theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    isLight = mode == ThemeMode.light;
    notifyListeners();
  }

  /// 启动时从持久化设置恢复
  Future<void> restore() async {
    try {
      final s = await SettingsStore.instance.load();
      setTheme(s['theme']?.toString() ?? 'system');
    } catch (_) {}
  }
}
