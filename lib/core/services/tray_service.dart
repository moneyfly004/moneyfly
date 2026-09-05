import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../l10n/app_strings.dart';
import '../models/models.dart';
import '../proxy/proxy_core.dart';

/// 桌面系统托盘（macOS/Windows）：
/// - 连接/断开（显示当前节点）
/// - 模式快捷切换（智能/全局）
/// - 国家/地区快速切换（前 8 个热门国家，点击切到该国最优/首个在线节点）
/// - 显示窗口 / 退出
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

  String _iconPath() => 'assets/moneyfly-logo.png';

  void _onStateChanged() => _updateMenu();

  /// 该国家当前应切换的节点：已测延迟最低的在线节点，否则首个在线/首个
  ProxyNode? _bestInCountry(ConnectionController ctrl, String code) {
    final candidates = ctrl.nodes
        .where((n) => (n.countryCode?.toUpperCase() ?? 'XX') == code)
        .toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      if (a.latencyMs < 0 && b.latencyMs < 0) return 0;
      if (a.latencyMs < 0) return 1;
      if (b.latencyMs < 0) return -1;
      return a.latencyMs.compareTo(b.latencyMs);
    });
    return candidates.first;
  }

  Future<void> _updateMenu() async {
    final ctrl = ConnectionController.instance;
    final connected = ctrl.status == ConnStatus.connected;
    final node = ctrl.current?.tag ?? '';

    // 模式子菜单（当前模式前加 ✓）
    final smart = ctrl.smartMode;
    final modeItems = <MenuItem>[
      MenuItem(
          label: '${smart ? '✓ ' : '   '}${AppStrings.t('smart_mode')}',
          key: 'mode:smart'),
      MenuItem(
          label: '${!smart ? '✓ ' : '   '}${AppStrings.t('global_mode')}',
          key: 'mode:global'),
    ];

    // 国家子菜单：按常用顺序取前 8 个有节点的国家
    final byCountry = <String>{};
    final countryItems = <MenuItem>[
      for (final code in ProxyNode.countryOrder)
        if (byCountry.add(code))
          if (ctrl.nodes.any(
              (n) => (n.countryCode?.toUpperCase() ?? 'XX') == code))
            MenuItem(
              label:
                  '${ProxyNode.countryFlags[code] ?? '🏳️'} ${ProxyNode.countryNames[code] ?? code}',
              key: 'country:$code',
            ),
    ];
    if (countryItems.isEmpty) {
      countryItems.add(MenuItem(
          label: AppStrings.t('no_available_nodes'), key: 'country:none', disabled: true));
    }

    final items = <MenuItem>[
      if (connected)
        MenuItem(label: '${AppStrings.t('disconnect')} ($node)', key: 'toggle')
      else
        MenuItem(label: AppStrings.t('connect'), key: 'toggle'),
      MenuItem.separator(),
      MenuItem.submenu(
          label: AppStrings.t('tray_mode'), submenu: Menu(items: modeItems)),
      MenuItem.submenu(
          label: AppStrings.t('tray_country'),
          submenu: Menu(items: countryItems)),
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
    final ctrl = ConnectionController.instance;
    final key = menuItem.key ?? '';
    if (key == 'mode:smart') {
      if (!ctrl.smartMode) unawaitedSafe(ctrl.toggleMode(true));
      return;
    }
    if (key == 'mode:global') {
      if (ctrl.smartMode) unawaitedSafe(ctrl.toggleMode(false));
      return;
    }
    if (key.startsWith('country:')) {
      final code = key.substring('country:'.length);
      final target = _bestInCountry(ctrl, code);
      if (target != null) {
        // switchNode(userInitiated:true)：连接时热切+锁定国家；
        // 未连接时预选节点并锁定（与首页点击国家行为一致）
        unawaitedSafe(ctrl.switchNode(target, userInitiated: true));
      }
      return;
    }
    switch (key) {
      case 'toggle':
        if (ctrl.status == ConnStatus.connected) {
          unawaitedSafe(ctrl.disconnect());
        } else {
          unawaitedSafe(ctrl.connect());
        }
      case 'show':
        onShowWindow?.call();
      case 'quit':
        onQuit?.call();
    }
  }

  void unawaitedSafe(Future<void> f) => f.catchError((_) {});

  void dispose() {
    ConnectionController.instance.removeListener(_onStateChanged);
    trayManager.removeListener(this);
  }
}
