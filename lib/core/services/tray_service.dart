import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../l10n/app_strings.dart';
import '../proxy/proxy_core.dart';

/// 桌面系统托盘（macOS/Windows）：连接/断开/显示窗口/退出。
/// 图标随连接状态变色（连接=绿、断开=灰；暂用默认 app 图标）。
class TrayService with TrayListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _initialized = false;
  void Function()? onShowWindow;
  void Function()? onQuit;

  Future<void> init({void Function()? showWindow, void Function()? quit}) async {
    if (_initialized || kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) return;
    onShowWindow = showWindow;
    onQuit = quit;
    trayManager.addListener(this);
    await trayManager.setIcon(_iconPath());
    await trayManager.setToolTip('MoneyFly');
    await _updateMenu();
    _initialized = true;
    ConnectionController.instance.addListener(_onStateChanged);
  }

  String _iconPath() {
    if (Platform.isMacOS) return 'assets/moneyfly-logo.png';
    if (Platform.isWindows) return 'assets/moneyfly-logo.png';
    return 'assets/moneyfly-logo.png';
  }

  void _onStateChanged() => _updateMenu();

  Future<void> _updateMenu() async {
    final connected = ConnectionController.instance.status == ConnStatus.connected;
    final node = ConnectionController.instance.current?.tag ?? '';
    final items = <MenuItem>[
      if (connected)
        MenuItem(label: '${AppStrings.t('disconnect')} ($node)', key: 'toggle')
      else
        MenuItem(label: AppStrings.t('connect'), key: 'toggle'),
      MenuItem.separator(),
      MenuItem(label: AppStrings.t('show_window'), key: 'show'),
      MenuItem.separator(),
      MenuItem(label: AppStrings.t('quit'), key: 'quit'),
    ];
    await trayManager.setContextMenu(Menu(items: items));
  }

  @override
  void onTrayIconMouseDown() => onShowWindow?.call();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'toggle':
        final ctrl = ConnectionController.instance;
        if (ctrl.status == ConnStatus.connected) {
          ctrl.disconnect();
        } else {
          ctrl.connect();
        }
      case 'show':
        onShowWindow?.call();
      case 'quit':
        onQuit?.call();
    }
  }

  void dispose() {
    ConnectionController.instance.removeListener(_onStateChanged);
    trayManager.removeListener(this);
  }
}
