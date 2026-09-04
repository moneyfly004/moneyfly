import 'dart:convert';
import 'dart:io';

import 'local_paths.dart';
import 'update_service.dart';

/// 订阅内容本地缓存（规格：订阅缓存 = 内存 + 本地，启动/离线可兜底）。
///
/// 缓存的是**订阅原文**（Clash YAML / base64 链接文本），读取后走与在线拉取
/// 完全相同的解析路径（[SubscriptionService]），保证新旧数据解析逻辑一致。
///
/// 写入时机：每次成功从网络拉取订阅后覆盖写入 —— 「软件运行拉取订阅后覆盖
/// 原来的配置信息」落到磁盘层。
/// 失效策略（三层，避免重装/换号后读到旧账号旧版本配置）：
/// 1. 安装级：缓存文件位于应用私有目录，卸载/清数据即随 install_id 一起消失；
///    重装后 install_id 不存在 → [AppDataCleaner] 启动时把缓存一并清除；
/// 2. 版本级：缓存记录写入时的 appVersion，应用升级后旧版缓存视为过期删除，
///    下次启动强制重新拉取（不沿用旧版本拉到的订阅）；
/// 3. 账号级：缓存绑定订阅 URL（每账号唯一），URL 变化（换号）即失效删除。
class SubscriptionCache {
  SubscriptionCache._();
  static final SubscriptionCache instance = SubscriptionCache._();

  static const fileName = 'subscription_cache.json';

  Future<File?> _file() async {
    final dir = await LocalPaths.supportDir();
    if (dir == null) return null;
    return File('${dir.path}/$fileName');
  }

  /// 覆盖写入缓存（成功拉取订阅后调用）
  Future<void> write({required String subscribeUrl, required String raw}) async {
    final f = await _file();
    if (f == null || subscribeUrl.isEmpty || raw.isEmpty) return;
    try {
      final dir = f.parent;
      if (!dir.existsSync()) await dir.create(recursive: true);
      await f.writeAsString(
        jsonEncode({
          'v': 1,
          'subscribeUrl': subscribeUrl,
          'appVersion': UpdateInfo.currentVersion,
          'fetchedAt': DateTime.now().toIso8601String(),
          'raw': raw,
        }),
        flush: true,
      );
    } catch (_) {
      // 缓存写失败不影响主流程（下次成功拉取会重写）
    }
  }

  /// 读取最近一次有效缓存；无效（版本过期 / 账号 URL 变化）则删除并返回 null
  Future<({String subscribeUrl, String raw})?> readLatest() async {
    final f = await _file();
    if (f == null) return null;
    try {
      if (!await f.exists()) return null;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) {
        await LocalPaths.deleteBestEffort(f);
        return null;
      }
      final m = Map<String, dynamic>.from(decoded);
      final url = m['subscribeUrl']?.toString() ?? '';
      final raw = m['raw']?.toString() ?? '';
      final ver = m['appVersion']?.toString() ?? '';
      // 版本升级（或当前无法确定版本时）→ 旧缓存过期，删除并强制重拉
      if (raw.isEmpty || url.isEmpty || ver != UpdateInfo.currentVersion) {
        await LocalPaths.deleteBestEffort(f);
        return null;
      }
      return (subscribeUrl: url, raw: raw);
    } catch (_) {
      // 解析失败视为坏缓存，删除
      await LocalPaths.deleteBestEffort(f);
      return null;
    }
  }

  /// 删除磁盘缓存（登出/切号/清数据时调用）
  Future<void> clear() async {
    final f = await _file();
    if (f == null) return;
    await LocalPaths.deleteBestEffort(f);
  }
}
