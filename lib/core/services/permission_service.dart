import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 平台权限服务（Android 走原生 MethodChannel；桌面端返回默认可用）
/// 对应 MainActivity.kt 的 top.moneyfly/vpn_permissions 通道
class PermissionService {
  PermissionService._();
  static final PermissionService instance = PermissionService._();

  static const _channel = MethodChannel('top.moneyfly/vpn_permissions');

  static bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 请求 VPN 授权（Android 弹系统授权框），返回是否已就绪
  Future<bool> prepareVpn() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('prepareVpn') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isVpnPrepared() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isVpnPrepared') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 是否已获得电池优化豁免（省电 + 防杀后台）
  Future<bool> isBatteryOptimizationIgnored() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isBatteryOptimizationIgnored') ?? false;
    } catch (_) {
      return true;
    }
  }

  Future<void> requestIgnoreBatteryOptimization() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimization');
    } catch (_) {}
  }

  Future<void> openBatterySettings() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('openBatterySettings');
    } catch (_) {}
  }

  /// 厂商名（MIUI/EMUI/ColorOS… 用于后台白名单引导）
  Future<String> getVendor() async {
    if (!_isAndroid) return 'desktop';
    try {
      return await _channel.invokeMethod<String>('getVendor') ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<bool> requestNotificationPermission() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 连接前一次性引导：VPN 授权 + 通知 + 电池豁免（最高权限防断连）
  /// 返回 false 表示用户拒绝 VPN 授权（不继续连接）
  Future<bool> ensureAllForConnect() async {
    final vpnOk = await prepareVpn();
    if (!vpnOk) return false;
    await requestNotificationPermission();
    final ignored = await isBatteryOptimizationIgnored();
    if (!ignored) {
      await requestIgnoreBatteryOptimization();
    }
    return true;
  }
}
