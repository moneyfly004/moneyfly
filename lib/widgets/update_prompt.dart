import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/proxy/proxy_core.dart';
import '../core/proxy/system_proxy.dart';
import '../core/services/app_log.dart';
import '../core/services/settings_store.dart';
import '../core/services/update_service.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// 新版本提示 + 「点击即更新」入口。
///
/// 三条路径（对齐 mclash 的更新体验）：
///   1. **后台预下载**：开启「自动下载更新包」时，检测到新版本就在后台把
///      **与本机平台/架构匹配**的包下好（带 sha256 校验），不打扰用户；
///   2. **提示**：进主界面后发现有新版本就弹一次，同一个版本只弹一次；
///      点「稍后」记住该版本，之后不再重复打扰；
///   3. **一键更新**：点「立即更新」→ 已下好直接装；没下好则显示下载进度并等待
///      （最多 3 分钟），装之前**先断开连接**，再调起系统安装器并退出自己。
abstract final class UpdatePrompt {
  UpdatePrompt._();

  /// 正在弹窗/检查/安装时为 true：避免后台下载完成触发的复查与用户操作打架，
  /// 出现「操作过程中又弹一次」。
  static bool _busy = false;

  /// 本次运行已提示过的版本（同一个版本一次运行只提示一次）
  static final Set<String> _promptedThisRun = {};

  /// 等待后台下载完成的上限
  @visibleForTesting
  static Duration debugWaitInstallerLimit = const Duration(minutes: 3);

  /// 手动检查更新的超时（超时按失败处理，别让用户对着转圈干等）
  static const Duration kManualCheckTimeout = Duration(seconds: 20);

  /// 测试缝：替换「退出进程」（真实路径是 exit(0)，会让测试进程直接消失）
  @visibleForTesting
  static void Function(int code)? debugExitOverride;

  /// 测试缝：替换「打开下载页」。
  /// 必须有：测试环境里 url_launcher 的通道调用**永不返回**（不抛异常，所以
  /// try/catch 救不了）—— 实测用它写用例会把整轮测试挂死。
  @visibleForTesting
  static Future<void> Function(String url)? debugOpenUrlOverride;

  @visibleForTesting
  static bool get debugBusy => _busy;

  @visibleForTesting
  static void debugReset() {
    _busy = false;
    _promptedThisRun.clear();
    debugWaitInstallerLimit = const Duration(minutes: 3);
    debugExitOverride = null;
    debugOpenUrlOverride = null;
  }

  static Future<String> _dismissed() async {
    final s = await SettingsStore.instance.load();
    return s['dismissedUpdateVersion']?.toString() ?? '';
  }

  /// 进入主界面后调用：已知有新版本就提示一次。
  static Future<void> maybePromptOnLaunch(BuildContext context) async {
    final info = UpdateService.lastInfo;
    final version = info?.latestVersion ?? '';
    if (!UpdateService.hasUpdate.value || version.isEmpty) return;
    if (_busy || _promptedThisRun.contains(version)) return;
    if (await _dismissed() == version) return; // 用户点过「稍后」
    _promptedThisRun.add(version);
    if (!context.mounted) return;
    await showUpdateDialog(context, info: info);
  }

  /// 手动检查更新（设置 →「版本更新」）。
  static Future<void> checkManually(BuildContext context) async {
    if (_busy || !context.mounted) return;
    _busy = true;
    final loading = _showLoadingDialog(context, AppStrings.t('update_checking'));
    UpdateInfo? info;
    var failed = false;
    try {
      info = await UpdateService.instance.check().timeout(kManualCheckTimeout);
    } on TimeoutException {
      failed = true;
    } catch (e) {
      failed = true;
      AppLog.error('check update failed: $e');
    } finally {
      loading.close();
      _busy = false;
    }
    if (!context.mounted) return;
    if (info == null || !info.isNewer) {
      await _alert(
        context,
        failed
            ? AppStrings.t('update_check_failed')
            : AppStrings.t('update_up_to_date',
                {'v': UpdateInfo.currentVersion}),
      );
      return;
    }
    _promptedThisRun.add(info.latestVersion);
    await showUpdateDialog(context, info: UpdateInfo(
      latestVersion: info.latestVersion,
      downloadUrl: info.downloadUrl,
      sizeText: info.sizeText,
      assetName: info.assetName,
      sha256: info.sha256,
    ), force: true);
  }

  /// 新版本弹窗。点「立即更新」进入下载/安装流程；点「稍后」记住该版本。
  static Future<void> showUpdateDialog(
    BuildContext context, {
    required UpdateInfo? info,
    bool force = false,
  }) async {
    final version = info?.latestVersion ?? '';
    if (version.isEmpty || !context.mounted) return;
    if (_busy) return;
    _busy = true;
    try {
      // 后台可能已经下好了 → 文案要如实区分「已就绪」与「正在后台下载」
      final downloaded = await UpdateService.instance.downloadedInstaller(info) != null;
      if (!context.mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: !force,
        builder: (ctx) => AlertDialog(
          backgroundColor: MFColors.card2,
          title: Text('${AppStrings.t('new_version')} v$version',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                downloaded
                    ? AppStrings.t('update_ready_body')
                    : (UpdateService.canInstallInApp
                        ? AppStrings.t('update_downloading_body')
                        : AppStrings.t('update_manual_body', {'v': version})),
                style: TextStyle(fontSize: 13, color: MFColors.txt2, height: 1.6),
              ),
              if (info!.sizeText != null && info.sizeText!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(AppStrings.t('update_body',
                    {'cur': 'v${UpdateInfo.currentVersion}', 'latest': 'v$version', 'size': ' · ${info.sizeText}'}),
                    style: TextStyle(fontSize: 12, color: MFColors.txt3, height: 1.6)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppStrings.t('later')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.t('update_install_now'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
      if (ok == true && context.mounted) {
        await installNow(context, info: info);
      } else if (ok == false) {
        // 记住「稍后」：同一个版本不再反复弹
        await SettingsStore.instance
            .update((s) => s['dismissedUpdateVersion'] = version);
      }
    } finally {
      _busy = false;
    }
  }

  /// 立即更新：已下好直接装；没下好就带进度下载（最多等 3 分钟），
  /// 仍失败则退化成「打开下载页手动下载」。
  static Future<void> installNow(
    BuildContext context, {
    required UpdateInfo? info,
  }) async {
    var path = await UpdateService.instance.downloadedInstaller(info);
    var cancelled = false;
    if (path == null && context.mounted) {
      final r = await _downloadWithProgress(context, info);
      path = r.path;
      cancelled = r.cancelled;
    }
    if (cancelled) {
      // 用户主动取消：不再等待下载（下载本身在后台继续，见弹窗里的说明），
      // 也**不能**当成「下载失败」去弹「是否打开下载页」——那是在反着用户的意思。
      return;
    }
    if (path == null) {
      // 不支持应用内安装（iOS）或下载失败 → 给下载页兜底
      if (!context.mounted) return;
      final url = info?.downloadUrl ?? '';
      if (url.isEmpty) {
        await _alert(context, AppStrings.t('no_download_url'));
        return;
      }
      final ok = await _confirm(context, AppStrings.t('update_download_failed'));
      if (ok == true) await openDownloadPage(url);
      return;
    }
    if (!context.mounted) return;
    if (!UpdateService.canInstallInApp) {
      await openDownloadPage(info?.downloadUrl ?? '');
      return;
    }

    // 装之前先断开：停内核 + 还原系统代理。
    // 否则安装器替换文件时可能被占用，且系统代理会残留指向死端口（整机断网）。
    try {
      await ConnectionController.instance.disconnect();
    } catch (e) {
      AppLog.error('disconnect before install failed: $e');
    }
    try {
      await SystemProxyManager.restore();
    } catch (_) {}

    final launched = await UpdateService.instance.launchInstaller(path);
    if (!context.mounted) return;
    if (!launched) {
      await _alert(context, AppStrings.t('update_install_launch_failed'));
      return;
    }
    if (Platform.isAndroid) {
      // 系统包安装器接管，本进程继续运行即可（用户装完自行返回）
      return;
    }
    await _alert(context, AppStrings.t('update_installing_exit'));
    // 让安装器独占文件（Windows Inno / macOS DMG）
    (debugExitOverride ?? exit)(0);
  }

  /// 显示进度弹窗并等待下载完成；超时或失败返回 path=null（cancelled=false）。
  ///
  /// 用户点「取消」时立即返回 `cancelled: true` 并关掉弹窗 —— 旧实现在这里
  /// `barrierDismissible: false` + `PopScope(canPop: false)` 且**没有取消按钮**，
  /// 一个可能持续几分钟的下载完全无法中止（连「不想装了」都表达不了）。
  /// 注意：底层下载是 UpdateService 里与「后台预下载」共享的同一份任务，
  /// 无法从 UI 侧 abort（服务层没有暴露 CancelToken），所以取消的语义是
  /// **停止等待 + 不安装**，弹窗文案已明确说明，不再有「关不掉」的死锁感。
  static Future<({String? path, bool cancelled})> _downloadWithProgress(
      BuildContext context, UpdateInfo? info) async {
    if (info?.downloadUrl == null || info!.downloadUrl!.isEmpty) {
      return (path: null, cancelled: false);
    }
    if (!context.mounted) return (path: null, cancelled: false);
    final progress = ValueNotifier<double?>(0);
    // 进度以全局 notifier 为准：后台预下载与用户点击可能共用同一份下载，
    // 谁在真正下载都会更新它。
    //
    // alive 闸门：取消/超时后我们会 dispose 上面这个 notifier，而底层下载
    // **还在继续**并不断回调 onProgress —— 直接写已 dispose 的 notifier 会在
    // debug 下抛「used after being disposed」。取消让它成为常见路径。
    var alive = true;
    void onTick() {
      if (alive) progress.value = UpdateService.downloadProgress.value;
    }

    UpdateService.downloadProgress.addListener(onTick);
    var cancelled = false;
    final cancelSignal = Completer<void>();
    final dialog = _showProgressDialog(context, progress, onCancel: () {
      if (cancelled) return;
      cancelled = true;
      if (!cancelSignal.isCompleted) cancelSignal.complete();
    });
    final download = UpdateService.instance.downloadInstaller(
      info: info,
      onProgress: (p) {
        if (alive) progress.value = p;
      },
    );
    String? path;
    try {
      // 下载与「取消」赛跑：取消后不再卡在等待上（Future.any 会吞掉落败分支
      // 之后才到达的错误，不会产生 unhandled async error）
      path = await Future.any<String?>([
        download.timeout(debugWaitInstallerLimit),
        cancelSignal.future.then((_) => null),
      ]);
    } catch (e) {
      AppLog.error('download installer failed: $e');
    } finally {
      alive = false;
      UpdateService.downloadProgress.removeListener(onTick);
      progress.dispose();
      dialog.close();
    }
    return (path: path, cancelled: cancelled && path == null);
  }

  /// 打开下载页（直链 = GitHub 上与本机平台/架构匹配的那个安装包）
  static Future<void> openDownloadPage(String url) async {
    if (url.isEmpty) return;
    final override = debugOpenUrlOverride;
    if (override != null) return override(url);
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLog.error('open download page failed: $e');
    }
  }

  // ==================== 小工具（弹窗句柄，保证一定能关掉）====================

  static _DialogHandle _showLoadingDialog(BuildContext context, String text) {
    final nav = Navigator.of(context, rootNavigator: true);
    var closed = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: MFColors.card2,
          content: Row(children: [
            const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2)),
            const SizedBox(width: 14),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ]),
        ),
      ),
    );
    return _DialogHandle(() {
      if (closed) return;
      closed = true;
      // 用弹窗自己的 navigator 关闭，且只关一次（历史上踩过「pop 错 navigator
      // 导致弹窗关不掉、用户只能重启」的坑）
      if (nav.canPop()) nav.pop();
    });
  }

  static _DialogHandle _showProgressDialog(
      BuildContext context, ValueListenable<double?> progress,
      {VoidCallback? onCancel}) {
    final nav = Navigator.of(context, rootNavigator: true);
    var closed = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: MFColors.card2,
          title: Text(AppStrings.t('update_downloading_pkg'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: v?.clamp(0, 1)),
                const SizedBox(height: 10),
                Text(
                  v == null ? '' : '${(v * 100).clamp(0, 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 12, color: MFColors.txt3),
                ),
                const SizedBox(height: 8),
                // 取消的真实语义写清楚：不再等待、不会安装；底层下载（与后台
                // 预下载共享）无法从 UI 侧 abort，所以如实说明而不是假装停掉
                Text(AppStrings.t('update_cancel_hint'),
                    style: TextStyle(
                        fontSize: 11, color: MFColors.txt3, height: 1.5)),
              ],
            ),
          ),
          actions: [
            if (onCancel != null)
              TextButton(
                onPressed: onCancel,
                child: Text(AppStrings.t('cancel')),
              ),
          ],
        ),
      ),
    );
    return _DialogHandle(() {
      if (closed) return;
      closed = true;
      if (nav.canPop()) nav.pop();
    });
  }

  static Future<void> _alert(BuildContext context, String text) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.card2,
        content: Text(text, style: const TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.t('confirm')),
          ),
        ],
      ),
    );
  }

  static Future<bool?> _confirm(BuildContext context, String text) async {
    if (!context.mounted) return null;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MFColors.card2,
        content: Text(text, style: const TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.t('confirm')),
          ),
        ],
      ),
    );
  }
}

/// 可关闭的弹窗句柄（幂等；用弹窗自己的 navigator 关，避免关错栈）
class _DialogHandle {
  _DialogHandle(this.close);
  final VoidCallback close;
}
