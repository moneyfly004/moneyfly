/// GitHub 国内镜像候选与地址改写。
///
/// 为什么需要（2026-09-23 线上问题）：App 的「检查更新」直连 `api.github.com`、
/// 下载直连 `github.com` —— 国内网络下这两个域名经常超时或被阻断，用户看到
/// 「检查更新失败」就永远停在旧版本，而旧版本没有线路轮换（主域名被墙时连登录
/// 都进不去），于是问题被放大成「连不上也用不了新版」。
///
/// 后端软件库早就用同一批镜像前缀做兜底（`internal/api/handlers/download.go`
/// 的 `download_proxy_prefixes`，线上实测可用），这里复用同一批地址，
/// 保证「面板里点得动」与「App 里点得动」取的是同一套通道。
///
/// 地址形式：`<前缀><原始完整 URL>`，例如
/// `https://ghfast.top/https://github.com/owner/repo/releases/download/v1/a.exe`
class GhMirror {
  GhMirror._();

  /// 镜像前缀（与后端默认值一致，2026-08 实测可用；顺序即尝试顺序）
  static const List<String> prefixes = [
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://gh.llkk.cc/',
    'https://gh.ddlc.top/',
  ];

  /// 是否已经是镜像地址（避免对镜像地址再叠一层前缀）
  static bool isMirrored(String url) => prefixes.any(url.trim().startsWith);

  /// 依次尝试的候选地址：**直连在前**，其后是各镜像。
  /// 返回空列表表示入参为空（调用方应直接放弃，不要发无效请求）。
  static List<String> candidates(String url) {
    final u = url.trim();
    if (u.isEmpty) return const [];
    if (isMirrored(u)) return [u];
    return [u, for (final p in prefixes) '$p$u'];
  }

  /// 取第 [index] 个候选；越界或入参为空时返回原地址（保证调用方永远拿得到可用值）
  static String at(String url, int index) {
    final list = candidates(url);
    if (list.isEmpty) return url;
    if (index <= 0) return list.first;
    if (index >= list.length) return list.last;
    return list[index];
  }
}
