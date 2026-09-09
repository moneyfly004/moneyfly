import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/serial_executor.dart';

/// 设置持久化（shared_preferences，JSON 序列化）。
///
/// 写路径收敛到本类：所有「读-改-写」必须走 [update]，落盘经全局串行队列，
/// 杜绝多写者并发 load→save 交错导致丢字段/旧快照覆盖（曾出现:设置页整份
/// 旧快照回写把其它模块刚写入的 lastSelectedTag 覆盖掉）。
/// 读 [load] 直读(带默认值合并)；直接 [save] 也入队保证落盘顺序。
class SettingsStore {
  SettingsStore._();
  static final SettingsStore instance = SettingsStore._();
  static const _p = 'moneyfly_settings_v1';

  /// 全局串行写队列：save/update 依次执行，避免并发交错
  static final SerialExecutor _writeQueue = SerialExecutor();

  Map<String, dynamic> _defaults() => {
        // #10：启动自动连接 / 断线自动重连 默认关闭（手动点击连接）
        'autoConnect': false,
        'autoTest': true,
        'autoReconnect': false,
        'reconnectTimes': 3,
        'testIntervalMin': 30,
        'dns': '223.5.5.5',
        // 主 DNS 列表(多源,提升解析成功率);fake-ip 过滤追加域名
        'dnsNameservers': <String>['223.5.5.5', '119.29.29.29'],
        'fakeIpFilterExtra': <String>[],
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
        // TUN 用户态栈（Android 机型兼容性切换：gvisor 兼容性最好 / mixed 更快）
        'tunStack': 'gvisor',
        // 内核日志级别（debug/info/warning/error；连接启动与实时页热更共用）
        'kernelLogLevel': 'warning',
        // DNS 解析模式：auto / fake-ip / redir-host
        'dnsMode': 'auto',
        // 按 App 分流/排除（Android）：all / selected / denied + 包名列表
        'accessControlMode': 'all',
        'accessControlApps': <String>[],
        // 用户自定义「直连名单」（域名后缀列表，命中直接不走代理）
        'bypassDomains': <String>[],
        'bypassLan': true,
        'theme': 'system',
        'language': 'zh',
        'notify': true,
        'crashReport': false,
        'analytics': false,
        'launchAtStartup': false,
        // 用户最后手动选择的节点 tag（跨重启恢复固定线路用）
        'lastSelectedTag': '',
        // 内核变体偏好:compatible / standard(桌面 amd64)
        'kernelVariant': 'compatible',
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

  /// 直接整体保存(整份快照,一般仅「恢复默认」用)；入队保证落盘顺序
  Future<void> save(Map<String, dynamic> settings) {
    return _enqueue(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_p, jsonEncode(settings));
    });
  }

  /// 原子「读-改-写」：所有写方都应走这里(在最新值上改一个/几个键再保存)，
  /// 与其它写方串行,杜绝旧快照覆盖/丢字段
  Future<void> update(void Function(Map<String, dynamic> current) mutate) {
    return _enqueue(() async {
      final s = await load();
      mutate(s);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_p, jsonEncode(s));
    });
  }

  /// 清空用户设置回默认（保留 defaults 语义）
  Future<void> reset() => update((s) => s.clear());

  static Future<void> _enqueue(Future<void> Function() job) => _writeQueue.run(job);
}
