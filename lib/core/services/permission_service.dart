import 'dart:async';

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

  /// 本会话是否已请求过电池豁免（避免每次连接都弹系统框把 App 切后台）
  bool _batteryPromptedThisSession = false;

  /// 连接前一次性引导：VPN 授权（必需，前置）+ 通知。
  /// 返回 false 表示用户拒绝 VPN 授权（不继续连接）。
  ///
  /// 关键修复：电池豁免会打开系统界面、把 App 切到后台，若在连接瞬间同步等待，
  /// 表现为「一点连接界面就自动缩小、随后断开」。故电池豁免改为：
  ///   1) 不阻塞连接（不 await）—— 连接立即继续；
  ///   2) 每会话至多请求一次 —— 不会每次连接都弹框打断。
  /// 豁免与否不影响本次隧道建立（VpnService 前台服务已足以维持连接）。
  Future<bool> ensureAllForConnect() async {
    final vpnOk = await prepareVpn();
    if (!vpnOk) return false;
    await requestNotificationPermission();
    unawaited(_maybeRequestBatteryOnce());
    return true;
  }

  Future<void> _maybeRequestBatteryOnce() async {
    if (_batteryPromptedThisSession) return;
    _batteryPromptedThisSession = true;
    try {
      if (!await isBatteryOptimizationIgnored()) {
        await requestIgnoreBatteryOptimization();
      }
    } catch (_) {}
  }
}
