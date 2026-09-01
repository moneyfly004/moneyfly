import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 设置持久化（shared_preferences，JSON 序列化）
class SettingsStore {
  SettingsStore._();
  static final SettingsStore instance = SettingsStore._();
  static const _p = 'moneyfly_settings_v1';

  Map<String, dynamic> _defaults() => {
        'autoConnect': true,
        'autoTest': true,
        'autoReconnect': true,
        'reconnectTimes': 3,
        'testIntervalMin': 30,
        'dns': '223.5.5.5',
        'protocolFilter': 'all',
        'defaultMode': 'smart', // smart / global
        'tunMode': 'auto',
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
