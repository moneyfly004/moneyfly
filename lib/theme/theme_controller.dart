import 'package:flutter/material.dart';

import '../core/services/settings_store.dart';

/// 主题控制器：全局单例，随设置「主题」切换。
/// MFColors 的颜色取值动态跟随 [isLight]，MaterialApp 随 [mode] 重建。
///
/// 「跟随系统」时 [isLight] 必须取**实际系统亮暗**（不能写死 false），
/// 并监听系统亮暗切换实时刷新 —— 否则系统为浅色时 MaterialApp 选浅色主题、
/// 而 MFColors 仍返回深色值，造成深浅混杂、文字发灰看不清。
class ThemeController extends ChangeNotifier with WidgetsBindingObserver {
  ThemeController._() {
    // 系统亮暗切换（跟随系统时）→ 同步 isLight 并刷新
    WidgetsBinding.instance.addObserver(this);
  }
  static final ThemeController instance = ThemeController._();

  bool isLight = false;
  ThemeMode mode = ThemeMode.dark;

  /// 当前系统是否为浅色外观
  bool get _systemIsLight =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.light;

  /// 系统外观变化回调（框架标准钩子，不与 MediaQuery 冲突）
  @override
  void didChangePlatformBrightness() {
    if (mode == ThemeMode.system) {
      final v = _systemIsLight;
      if (v != isLight) {
        isLight = v;
        notifyListeners();
      }
    }
  }

  /// 设置页「主题」变更入口（light / dark / system）
  void setTheme(String theme) {
    mode = switch (theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    // 「跟随系统」→ 取实际系统亮暗；固定值直接映射
    isLight = switch (mode) {
      ThemeMode.light => true,
      ThemeMode.dark => false,
      ThemeMode.system => _systemIsLight,
    };
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
