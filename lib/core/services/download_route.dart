import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../api/gh_mirror.dart';
import '../proxy/proxy_core.dart';
import 'settings_store.dart';

/// 下载路由：**已连接时走隧道，未连接时走「直连 + 加速镜像」**。
///
/// 背景（2026-10 客户反馈）：
/// - 国内网络直连 `github.com` 经常超时/被阻断，所以「未连接」时必须靠镜像；
/// - 但用户一旦连上 VPN，隧道本身就能直达 GitHub —— 还死磕镜像反而是绕远路：
///   镜像站本身也经常挂（实测 ghfast.top 403、gh.llkk.cc 连不上、gh.ddlc.top 429），
///   于是「已经能翻墙却下载失败」。
///
/// 因此统一成：
/// 1. 已连接（内核在跑 + 桌面端有本地混合端口）→ **只走直连**，并给 Dio 显式
///    挂 `findProxy = "PROXY 127.0.0.1:<localPort>"`，保证 App 自己的请求真的进隧道
///    （App 的进程流量不走系统代理，必须显式指定，见 KernelManager 的同类处理）；
/// 2. 未连接（或移动端内嵌内核没有本地混合端口）→ 保持旧逻辑：直连 → 各镜像。
///
/// 适用范围：软件安装包下载、国家库/分流规则（geo）下载。
class DownloadRoute {
  DownloadRoute._();

  /// 隧道可用：内核已连接 **且** 当前平台由 CLI 内核提供本地混合端口。
  ///
  /// 移动端（Android VpnService / iOS NEPacketTunnel）的内核跑在系统隧道里，
  /// 没有 `127.0.0.1:<port>` 监听；App 自身流量要么随 VPN 走（直连即可），
  /// 要么被排除在外（需要镜像兜底），所以移动端不套显式代理。
  static bool get tunneled =>
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
      ConnectionController.instance.status == ConnStatus.connected;

  /// 本地混合端口（设置项 `localPort`，默认 2080）
  static Future<int> localPort() async {
    try {
      final s = await SettingsStore.instance.load();
      return (s['localPort'] as num?)?.toInt() ?? 2080;
    } catch (_) {
      return 2080;
    }
  }

  /// 候选下载地址：
  /// - 已连接 → 只给直连地址（经隧道，无需镜像）；
  /// - 未连接 → 直连 + 各加速镜像（[GhMirror.candidates] 的旧行为）。
  static List<String> candidates(String url) =>
      tunneled ? [url] : GhMirror.candidates(url);

  /// 本类是否给某个 Dio 装过隧道代理（断开后需要撤掉，否则一直走已失效的端口）
  static final Set<Dio> _proxied = <Dio>{};

  /// 给 Dio 装上/撤掉隧道代理。**每次下载前都调用**：
  /// - 已连接 → 挂 `PROXY 127.0.0.1:<port>`；
  /// - 未连接且之前挂过 → 还原成裸直连，避免断开后还往死端口发请求；
  /// - 未连接且从未挂过 → **不动适配器**（测试注入的假适配器不能被覆盖，
  ///   调用方自定义的适配器同理）。
  static Future<void> applyTo(Dio dio) async {
    if (tunneled) {
      final port = await localPort();
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          c.connectionTimeout = const Duration(seconds: 15);
          c.findProxy = (_) => 'PROXY 127.0.0.1:$port';
          return c;
        },
      );
      _proxied.add(dio);
    } else if (_proxied.remove(dio)) {
      dio.httpClientAdapter = IOHttpClientAdapter();
    }
  }
}
