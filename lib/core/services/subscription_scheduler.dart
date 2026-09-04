import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../proxy/proxy_core.dart';
import 'account_service.dart';
import 'subscription_service.dart';

/// 登录期间的「定时更新订阅」调度器（固定每 30 分钟一次静默刷新）。
///
/// 规格要求：订阅内容每次连接前刷新（或 30 分钟缓存 + 手动刷新），并静默
/// 定时更新 —— 本调度器在登录态建立后启动，周期执行：
/// 1. 重拉订阅信息并重新判定账号状态（到期/设备满/禁用，首页横幅/门禁联动）；
/// 2. 强制重拉订阅原文 → 覆盖本地缓存与内存节点（运行期间节点/线路保持最新）；
/// 3. 刷新结果安全合并进连接控制器（已连接且当前线路不在新订阅中时保持现状，
///    不打断正在使用的连接）。
///
/// 失败策略：单次失败静默跳过，保留旧节点继续可用，等下一周期或下次
/// 回前台（距上次成功 ≥10 分钟）再试 —— 网络抖动不会清空用户可用节点，
/// 也不会弹窗打扰。
class SubscriptionScheduler {
  SubscriptionScheduler._();
  static final SubscriptionScheduler instance = SubscriptionScheduler._();

  /// 固定间隔：30 分钟（与规格「手动刷新 + 每 30 分钟静默刷新」一致）
  static const interval = Duration(minutes: 30);

  /// 回前台最小刷新间隔：距上次成功不足 10 分钟不重复拉
  static const resumeMinGap = Duration(minutes: 10);

  Timer? _timer;
  bool _started = false;
  bool _busy = false;
  DateTime _lastSuccess = DateTime.fromMillisecondsSinceEpoch(0);

  bool get started => _started;

  /// 登录态建立后调用（SessionState 变 true）；重复调用幂等
  void start() {
    if (_started) return;
    // 测试环境不启定时器（flutter_test 会因残留周期 Timer 报错）
    if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) return;
    _started = true;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  /// 登出/会话失效后调用（SessionState 变 false）
  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }

  /// 应用回前台：距上次成功刷新 ≥10 分钟则立即静默刷新一次
  Future<void> onAppResumed() async {
    if (!_started) return;
    if (DateTime.now().difference(_lastSuccess) < resumeMinGap) return;
    await _tick();
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final ok = await _refreshOnce();
      if (ok) _lastSuccess = DateTime.now();
    } finally {
      _busy = false;
    }
  }

  Future<bool> _refreshOnce() async {
    // 未登录（token 缺失）时跳过
    final token = await ApiClient.readAccessToken();
    if (token == null || token.isEmpty) return false;
    // 1) 订阅信息 + 账号状态判定（失败不阻塞，保留上次判定）
    try {
      await AccountService.instance.refresh(force: true);
    } catch (_) {}
    // 2) 强制重拉订阅原文（成功覆盖本地缓存 + 内存），失败回退本地缓存
    try {
      final nodes =
          await SubscriptionService.instance.fetchNodes(force: true);
      // 3) 安全合并：不打断正在使用的连接
      await ConnectionController.instance.applySubscriptionNodes(nodes);
      return nodes.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
