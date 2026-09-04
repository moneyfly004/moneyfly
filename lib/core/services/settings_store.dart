import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 设置持久化（shared_preferences，JSON 序列化）
class SettingsStore {
  SettingsStore._();
  static final SettingsStore instance = SettingsStore._();
  static const _p = 'moneyfly_settings_v1';

  Map<String, dynamic> _defaults() => {
        // #10：启动自动连接 / 断线自动重连 默认关闭（手动点击连接）
        'autoConnect': false,
        'autoTest': true,
        'autoReconnect': false,
        'reconnectTimes': 3,
        'testIntervalMin': 30,
        'dns': '223.5.5.5',
        'defaultMode': 'smart', // smart / global
        // 本机代理监听端口（mixed 入站 + 系统代理指向的端口），默认 2080
        'localPort': 2080,
        // Clash API 管理端口（切节点/测速/流量统计），默认 9090
        'clashApiPort': 9090,
        // 测速探测地址（内核 delay 测试；网络环境特殊时可改）
        'testUrl': 'http://www.gstatic.com/generate_204',
        // 桌面端默认「仅系统代理」（TUN 需 root，默认开会导致连接失败）；
        // Android/iOS 默认「TUN + 系统代理双通道」（VpnService 授权后 TUN 接管）
        'tunMode': (Platform.isAndroid || Platform.isIOS) ? 'auto' : 'off',
        'bypassLan': true,
        'theme': 'system',
        'language': 'zh',
        'notify': true,
        'crashReport': false,
        'analytics': false,
      };

  Future<Map<String, dynamic>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_p);
    if (raw == null) return _defaults();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {..._defaults(), ...Map<String, dynamic>.from(decoded)};
      }
    } catch (_) {}
    return _defaults();
  }

  Future<void> save(Map<String, dynamic> settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_p, jsonEncode(settings));
  }
}
