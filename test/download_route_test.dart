import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/api/gh_mirror.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/services/download_route.dart';

/// 下载路由：**已连接走隧道直连，未连接走「直连 + 镜像」**。
///
/// 客户实测场景：
/// - 未连 VPN：github.com 在国内不可达 → 必须保留镜像兜底（旧行为）；
/// - 已连 VPN：隧道能直达 GitHub，却还去试镜像（ghfast.top 403 / gh.llkk.cc
///   连不上 / gh.ddlc.top 429）→ 下载反而失败。所以已连接时**只走直连**。
void main() {
  const url = 'https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat';

  tearDown(() {
    ConnectionController.instance.status = ConnStatus.disconnected;
  });

  test('未连接：候选 = 直连 + 各镜像（保留旧兜底逻辑）', () {
    ConnectionController.instance.status = ConnStatus.disconnected;
    final list = DownloadRoute.candidates(url);
    expect(list.length, GhMirror.prefixes.length + 1);
    expect(list.first, url, reason: '直连永远排第一');
    expect(list.skip(1).every((u) => GhMirror.prefixes.any(u.startsWith)), isTrue);
    expect(DownloadRoute.tunneled, isFalse);
  });

  test('已连接（桌面端）：候选只有直连，走隧道', () {
    ConnectionController.instance.status = ConnStatus.connected;
    expect(DownloadRoute.tunneled, isTrue,
        reason: '测试跑在 macOS，桌面端 + 已连接 = 有本地混合端口');
    final list = DownloadRoute.candidates(url);
    expect(list, [url], reason: '已连接时不该再浪费时间试镜像');
  });

  test('镜像列表里不再包含已失效的站点', () {
    expect(GhMirror.prefixes, isNot(contains('https://ghfast.top/')));
    expect(GhMirror.prefixes, isNot(contains('https://gh.llkk.cc/')));
    expect(GhMirror.prefixes, isNot(contains('https://gh.ddlc.top/')));
    expect(GhMirror.prefixes, isNotEmpty, reason: '未连接时必须至少有一个镜像可用');
  });
}
