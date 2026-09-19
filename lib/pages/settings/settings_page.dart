import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/services/app_log.dart';
import '../../core/services/autostart.dart';
import '../../core/services/crash_logger.dart';
import '../../core/services/settings_store.dart';
import '../../core/services/subscription_service.dart';
import '../../core/services/update_service.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/mf_input.dart';
import '../../widgets/mf_row.dart';
import '../auth/change_password_page.dart';
import 'access_page.dart';
import 'bypass_page.dart';
import 'geo_update_page.dart';
import 'kernel_page.dart';
import 'log_center_page.dart';

/// 主 DNS 列表默认值（阿里 223.5.5.5 + 腾讯 119.29.29.29，国内可达）
const _defaultDnsServers = ['223.5.5.5', '119.29.29.29'];

/// 设置页（设计稿 09）：完整清单 + 持久化
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic> _s = {};
  bool _loaded = false;


  @override
  void initState() {
    super.initState();
    SettingsStore.instance.load().then((v) {
      if (mounted) {
        setState(() {
          _s = v;
          _loaded = true;
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  Future<void> _set(String key, dynamic value) async {
    setState(() => _s[key] = value);
    // 连接相关设置即时生效到连接控制器（自动测速/断线重连/默认模式）
    ConnectionController.instance.applySettings(_s);
    // 基于最新值只改这一键再保存(update 单写队列),避免整份旧快照回写
    // 覆盖其它模块(如 lastSelectedTag/kernelVariant)刚写入的值
    await SettingsStore.instance.update((s) => s[key] = value);
  }

@override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(body: Center(child: CircularProgressIndicator(color: MFColors.brand)));
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('settings_title')),
        actions: [
          TextButton(
            onPressed: () async {
              await SettingsStore.instance.reset();
              final defaults = await SettingsStore.instance.load();
              if (!mounted) return;
              setState(() => _s = defaults);
              // 默认值同步生效到连接控制器与主题
              ConnectionController.instance.applySettings(defaults);
              ThemeController.instance.setAppearance(defaults['appearance']?.toString() ?? 'light');
              _toast(AppStrings.t('restored'));
            },
            child: Text(AppStrings.t('restore_default'), style: TextStyle(fontSize: 12.5, color: MFColors.txt3)),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
          children: [
            // ① 连接与线路：用什么模式连、怎么自动连/重连/测速
            _section(AppStrings.t('group_connect')),
            _row(icon: '🎯', title: AppStrings.t('settings_default_mode'),
                trailing: _seg2(
                  left: AppStrings.t('smart_mode'), right: AppStrings.t('global_mode'),
                  selectedLeft: _s['defaultMode'] != 'global',
                  onLeft: () => _set('defaultMode', 'smart'),
                  onRight: () => _set('defaultMode', 'global'),
                )),
            _row(icon: '🔌', title: AppStrings.t('settings_auto_connect'),
                trailing: _switch(_s['autoConnect'] == true, (v) => _set('autoConnect', v))),
            if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) ...[
              _row(icon: '🚀', title: AppStrings.t('settings_launch_startup'),
                  trailing: _switch(_s['launchAtStartup'] == true, (v) async {
                    // 先落系统、成功才落设置。旧实现是先写设置再 unawaited(enable())：
                    // 插件在没 setup 时抛 UnsupportedError 被 unawaited 吞掉，于是
                    // 开关显示「已开启」而系统里从没注册过 —— 失败必须让用户看见，
                    // 且不能让设置项停在「开着」的假状态。
                    final ok = v
                        ? await AutostartService.enable()
                        : await AutostartService.disable();
                    if (!ok) {
                      _toast(AppStrings.t('launch_at_startup_failed'));
                      return;
                    }
                    await _set('launchAtStartup', v);
                  })),
              _row(icon: '🚪', title: AppStrings.t('close_action'),
                  value: _closeActionLabel(),
                  onTap: _pickCloseAction),
            ],
            _row(icon: '⚡', title: AppStrings.t('settings_auto_test'), desc: AppStrings.t('settings_auto_test_desc'),
                trailing: _switch(_s['autoTest'] == true, (v) => _set('autoTest', v))),
            _row(icon: '🔁', title: AppStrings.t('settings_reconnect'), desc: AppStrings.t('settings_reconnect_desc'),
                trailing: _switch(_s['autoReconnect'] == true, (v) => _set('autoReconnect', v))),
            _row(icon: '⏱️', title: AppStrings.t('settings_test_interval'), value: _testIntervalValue(),
                onTap: () => _picker(['15 ${AppStrings.t('settings_minutes')}', '30 ${AppStrings.t('settings_minutes')}', '60 ${AppStrings.t('settings_minutes')}'], (v) => _set('testIntervalMin', int.parse(v.split(' ').first)),
                    current: _testIntervalValue())),
            _row(icon: '🧭', title: AppStrings.t('settings_test_url'), desc: AppStrings.t('settings_test_url_desc'),
                value: _testUrlHost(),
                onTap: _pickTestUrl),
            // ② 代理与分流：TUN、DNS、直连名单、按应用分流
            _section(AppStrings.t('group_proxy')),
            // TUN 模式行只在**真的能选**的平台显示：Android/iOS 的 tunMode 会被
            // 内核侧强制成 auto（移动端只能走系统隧道），显示出来是个点了没用的
            // 假开关 —— 用户以为自己关掉了 TUN，其实仍在走（旧实现 iOS 正是如此）。
            if (!Platform.isAndroid && !Platform.isIOS)
              _row(icon: '🚀', title: AppStrings.t('settings_tun'),
                  desc: _tunDesc(),
                  value: _tunModeValue(),
                  onTap: _pickTunMode),
            if (Platform.isAndroid)
              _row(icon: '🧱', title: AppStrings.t('settings_tun_stack'),
                  desc: AppStrings.t('settings_tun_stack_desc'),
                  value: _tunStackValue(),
                  onTap: () => _picker([
                    AppStrings.t('tun_stack_gvisor'),
                    AppStrings.t('tun_stack_mixed'),
                  ], (v) => _set('tunStack',
                      v == AppStrings.t('tun_stack_mixed') ? 'mixed' : 'gvisor'),
                      current: _tunStackValue())),
            // 主 DNS 列表（逗号分隔文本编辑；旧 'dns' 单值键保留兼容，主列表优先）
            _row(icon: '🌐', title: AppStrings.t('settings_dns'),
                desc: AppStrings.t('settings_dns_desc'),
                value: _dnsList().join(', '),
                onTap: _pickDnsList),
            _row(icon: '🧭', title: AppStrings.t('settings_dns_mode'),
                desc: AppStrings.t('settings_dns_mode_desc'),
                value: _dnsModeValue(),
                onTap: () => _picker([
                  AppStrings.t('dns_mode_auto'),
                  AppStrings.t('dns_mode_fakeip'),
                  AppStrings.t('dns_mode_redirhost'),
                ], (v) => _set('dnsMode',
                    v == AppStrings.t('dns_mode_fakeip')
                        ? 'fake-ip'
                        : (v == AppStrings.t('dns_mode_redirhost')
                            ? 'redir-host'
                            : 'auto')),
                    current: _dnsModeValue())),
            // fake-ip 过滤追加（这些域名保留真实解析，不映射 fake-ip）
            _row(icon: '🧩', title: AppStrings.t('settings_fakeip_extra'),
                desc: AppStrings.t('settings_fakeip_extra_desc'),
                value: '${_fakeIpExtra().length}',
                onTap: _pickFakeIpFilter),
            // UDP+TLS 协议（hysteria/hysteria2/tuic）证书校验放宽：
            // 这类节点几乎都用伪装 SNI + 不匹配证书，开着校验必然握不上手
            // （实测 17/17 失败 → 关掉后 16/17 成功）。默认开，可关。
            _row(icon: '🔓', title: AppStrings.t('settings_udp_insecure'),
                desc: AppStrings.t('settings_udp_insecure_desc'),
                trailing: _switch(_s['udpSkipCertVerify'] != false,
                    (v) => _set('udpSkipCertVerify', v))),
            _row(icon: '🏠', title: AppStrings.t('settings_bypass_lan'),
                trailing: _switch(_s['bypassLan'] == true, (v) => _set('bypassLan', v))),
            _row(icon: '🚫', title: AppStrings.t('settings_bypass'),
                desc: AppStrings.t('settings_bypass_desc'),
                value: '${((_s['bypassDomains'] as List?)?.length ?? 0)}',
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BypassPage()))),
            if (Platform.isAndroid)
              _row(icon: '📱', title: AppStrings.t('settings_access'),
                  desc: AppStrings.t('settings_access_desc'),
                  value: _accessModeValue(),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AccessPage()))),
            // ③ 网络与端口（低频/高级）
            _section(AppStrings.t('group_network')),
            _row(icon: '🔢', title: AppStrings.t('settings_local_port'),
                desc: AppStrings.t('settings_local_port_desc'),
                value: '${_s['localPort'] ?? 2080}',
                onTap: _pickLocalPort),
            _row(icon: '🔧', title: AppStrings.t('settings_clash_api_port'),
                desc: AppStrings.t('settings_clash_api_port_desc'),
                value: '${_s['clashApiPort'] ?? 9090}',
                onTap: _pickClashApiPort),
            // ④ 内核与数据
            _section(AppStrings.t('group_kernel')),
            _row(icon: '🧩', title: AppStrings.t('settings_kernel'),
                desc: 'MetaCubeX/mihomo',
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const KernelPage()))),
            _row(icon: '🌍', title: AppStrings.t('settings_geo_data'),
                desc: AppStrings.t('settings_geo_data_desc'),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GeoUpdatePage()))),
            // ⑤ 外观
            _section(AppStrings.t('group_appearance')),
            _appearanceRow(),
            _row(icon: '🌏', title: AppStrings.t('settings_language'),
                value: AppStrings.lang == 'en' ? 'English' : '简体中文',
                onTap: _pickLanguage),
            _row(icon: '🪪', title: AppStrings.t('settings_subscribe_ua'),
                desc: AppStrings.t('settings_subscribe_ua_desc'),
                value: ((_s['subscribeUserAgent']?.toString() ?? '').trim().isEmpty)
                    ? AppStrings.t('settings_subscribe_ua_default')
                    : _s['subscribeUserAgent'].toString(),
                onTap: _pickSubscribeUa),
            // ⑥ 账户
            _section(AppStrings.t('group_account')),
            _row(icon: '🔑', title: AppStrings.t('settings_change_pwd'), desc: AppStrings.t('cur_pwd'), onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChangePasswordPage()))),
            _row(icon: '🧹', title: AppStrings.t('settings_clear_data'),
                desc: AppStrings.t('settings_clear_data_desc'),
                danger: true,
                onTap: _clearLocalData),
            // ⑦ 关于与诊断
            _section(AppStrings.t('group_about')),
            if (Platform.isAndroid || Platform.isWindows || Platform.isMacOS)
              _row(icon: '⬇️', title: AppStrings.t('settings_auto_download_update'),
                  desc: AppStrings.t('settings_auto_download_update_desc'),
                  trailing: _switch(_s['autoDownloadUpdatePkg'] == true,
                      (v) => _set('autoDownloadUpdatePkg', v))),
            _row(icon: '📋', title: AppStrings.t('log_center_title'),
                desc: AppStrings.t('log_center_desc'),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogCenterPage()))),
            _row(icon: '💥', title: AppStrings.t('settings_crash_report'),
                desc: AppStrings.t('settings_crash_report_desc'),
                trailing: _switch(_s['crashReport'] == true, (v) {
                  setState(() => _s['crashReport'] = v);
                  CrashLogger.setEnabled(v);
                  _set('crashReport', v);
                })),
            const SizedBox(height: 12),
             Center(
              child: Text('MoneyFly v${UpdateInfo.currentVersion} · dy.moneyfly.top',
                  style: TextStyle(fontSize: 10.5, color: MFColors.txt3, fontFamily: kNumFont)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
      child: Text(title,
          style:  TextStyle(fontSize: 11, color: MFColors.txt3, fontWeight: FontWeight.w700, letterSpacing: 2)),
    );
  }

  /// 统一行组件。原实现是 `Container(height: 52)` + 「标题/描述」和「值(≤150px)」
  /// 挤同一行 —— 380 宽（最小窗口）下描述只剩 ~94px，中英文描述都会被裁掉并抛
  /// RenderFlex overflow（实测 37 次）。现在委托给 MFRow：最小高度 + 描述独占一行。
  Widget _row({
    required String icon,
    required String title,
    String? desc,
    String? value,
    Widget? trailing,
    bool danger = false,
    bool showDot = false,
    VoidCallback? onTap,
  }) {
    return MFRow(
      icon: icon,
      title: title,
      desc: desc,
      value: value,
      trailing: trailing,
      danger: danger,
      showDot: showDot,
      onTap: onTap,
    );
  }

  Widget _switch(bool value, ValueChanged<bool> onChanged) {
    return Transform.scale(scale: .82, child: Switch(value: value, onChanged: onChanged));
  }

  /// 外观选择：6 套完整外观模式（背景 + 卡片 + 品牌整套切换），点击即切（立即生效 + 持久化）
  Widget _appearanceRow() {
    final current = ThemeController.instance.appearance;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      decoration: BoxDecoration(
          color: MFColors.card,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: MFColors.line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                    color: MFColors.card2, borderRadius: BorderRadius.circular(9)),
                alignment: Alignment.center,
                child: const Text('🎨', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(AppStrings.t('settings_theme'),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: MFColors.txt)),
              ),
              Text(
                  AppStrings.t(
                      mfThemeLabels[current] ?? 'appearance_light'),
                  style: TextStyle(
                      fontSize: 12,
                      color: MFColors.brand,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final key in mfThemeKeys)
                // 外观色卡同样要有按压反馈（旧实现 GestureDetector + Container，
                // 按下去毫无反应）；色卡底色画在 Ink 上，水波纹才看得见
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      ThemeController.instance.setAppearance(key);
                      _set('appearance', key);
                    },
                    borderRadius: BorderRadius.circular(9),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Ink(
                          width: 42,
                          height: 30,
                          decoration: BoxDecoration(
                            color: mfThemeOf(key).card,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: current == key
                                  ? MFColors.brand
                                  : mfThemeOf(key).line,
                              width: current == key ? 2 : 1,
                            ),
                          ),
                          child: Center(
                            child: Container(
                              width: 11,
                              height: 11,
                              decoration: BoxDecoration(
                                  color: mfThemeOf(key).brand,
                                  shape: BoxShape.circle),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                            AppStrings.t(mfThemeLabels[key] ?? ''),
                            style: TextStyle(
                                fontSize: 10,
                                color: current == key
                                    ? MFColors.brand
                                    : MFColors.txt3,
                                fontWeight: current == key
                                    ? FontWeight.w700
                                    : FontWeight.w500)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 两段式开关（智能/全局 等）。
  ///
  /// 标签必须能压缩：它作为「行尾控件」时拿到的宽度可能很窄（英文标签 + 380 宽
  /// 最小窗口），旧实现两个 Text 都没有 maxLines/省略号，实测整行溢出 19px 并把
  /// 标题挤成 0 宽（标题完全看不见）。现在每个标签 Flexible + 单行省略。
  ///
  /// 可点区域用 InkWell（审计 P2）：旧实现是 GestureDetector + Container，按下去
  /// 没有任何反馈。渐变底必须画在 `Ink` 上（不是 Container）—— Material 的墨水层
  /// 在子 widget **下面**，用不透明 Container 会把水波纹整个盖住。
  Widget _seg2({required String left, required String right, required bool selectedLeft,
      required VoidCallback onLeft, required VoidCallback onRight}) {
    Widget seg(String label, bool selected, VoidCallback onTap) {
      return Flexible(
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              gradient: selected ? MFColors.brandGradient : null,
              borderRadius: BorderRadius.circular(7),
            ),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(7),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                child: Text(label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : MFColors.txt3)),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: MFColors.card2, borderRadius: BorderRadius.circular(9)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(left, selectedLeft, onLeft),
          seg(right, !selectedLeft, onRight),
        ],
      ),
    );
  }

  String _accessModeValue() {
    return switch (_s['accessControlMode']?.toString()) {
      'selected' => AppStrings.t('access_mode_selected'),
      'denied' => AppStrings.t('access_mode_denied'),
      _ => AppStrings.t('access_mode_all'),
    };
  }

  /// 后台测速间隔的展示文案（同时用作选择器「当前值」判定，两者必须同源）
  String _testIntervalValue() =>
      '${_s['testIntervalMin'] ?? 30} ${AppStrings.t('settings_minutes')}';

  /// TUN 堆栈展示文案（同上，行内展示与选择器勾选同源）
  String _tunStackValue() =>
      (_s['tunStack']?.toString() ?? 'gvisor') == 'mixed'
          ? AppStrings.t('tun_stack_mixed')
          : AppStrings.t('tun_stack_gvisor');

  /// DNS 模式展示文案（同上）
  String _dnsModeValue() {
    return switch (_s['dnsMode']?.toString()) {
      'fake-ip' => AppStrings.t('dns_mode_fakeip'),
      'redir-host' => AppStrings.t('dns_mode_redirhost'),
      _ => AppStrings.t('dns_mode_auto'),
    };
  }

  /// TUN 模式展示文案（同上）
  String _tunModeValue() {
    return switch (_s['tunMode']?.toString()) {
      'off' => AppStrings.t('tun_off'),
      'force' => AppStrings.t('tun_force'),
      _ => AppStrings.t('tun_auto'),
    };
  }

  String? _tunDesc() {
    final mode = _s['tunMode']?.toString() ?? 'off';
    if (mode == 'off') return AppStrings.t('tun_off_hint');
    if (Platform.isAndroid || Platform.isIOS) return null;
    if (Platform.isWindows) return AppStrings.t('tun_need_admin');
    if (Platform.isMacOS) return AppStrings.t('tun_need_root');
    return null;
  }

  /// 校验型文本对话框：**校验在对话框内部执行**。
  ///
  /// 旧实现（审计 P1）四个对话框是同一个坏模式：`Navigator.pop(ctx, ctrl.text)`
  /// **先关闭**，关闭之后才校验，失败只能 `_toast` 闪 4 秒 snackbar —— 用户（尤其是
  /// 一次性粘贴一整串 DNS 的）输入全被丢掉，必须重新打开对话框、重新输入。
  /// 现在 [validate] 返回非 null（错误文案）时：对话框**不关**、错误常驻在输入框
  /// 下方（InputDecoration.errorText）、已输入内容原样保留，用户可以就地改。
  Future<String?> _askText({
    required String title,
    required String initial,
    required String? Function(String raw) validate,
    String? hint,
    String? helper,
    TextInputType? keyboardType,
    int? minLines,
    int? maxLines,
    TextStyle? style,
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(builder: (ctx, setDlg) {
          void submit() {
            final e = validate(ctrl.text);
            if (e != null) {
              setDlg(() => error = e);
              return; // 校验不过：不 pop，输入与错误都留在对话框里
            }
            Navigator.pop(ctx, ctrl.text);
          }

          return AlertDialog(
            backgroundColor: MFColors.card2,
            title: Text(title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: keyboardType,
              minLines: minLines,
              maxLines: maxLines,
              style: style ?? TextStyle(color: MFColors.txt),
              onSubmitted: (_) => submit(),
              decoration: _mfInputErr(hint: hint, helper: helper, error: error),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppStrings.t('cancel_text')),
              ),
              TextButton(
                onPressed: submit,
                child: Text(AppStrings.t('save'),
                    style: TextStyle(color: MFColors.brandLight)),
              ),
            ],
          );
        });
      },
    );
  }

  /// 端口输入弹窗通用件：返回合法端口；[forbidden] 返回与之冲突的值时应拒绝
  Future<int?> _askPort(String title, String hint, int cur, String invalidMsg,
      int? forbidden, {String? helper}) async {
    final v = await _askText(
      title: title,
      initial: '$cur',
      hint: hint,
      helper: helper ?? AppStrings.t('settings_local_port_desc'),
      keyboardType: TextInputType.number,
      validate: (raw) {
        final p = int.tryParse(raw.trim());
        if (p == null ||
            p < 1024 ||
            p > 65535 ||
            (forbidden != null && p == forbidden)) {
          return invalidMsg;
        }
        return null;
      },
    );
    if (v == null) return null;
    return int.tryParse(v.trim());
  }

  /// 保存端口类设置：已连接 → 自动断开并用新值重连（内核重启后才生效）
  Future<void> _applyPortChange(String key, int value) async {
    await _set(key, value);
    final conn = ConnectionController.instance;
    if (conn.status == ConnStatus.connected) {
      _toast(AppStrings.t('local_port_reconnect'));
      unawaited(() async {
        await conn.disconnect();
        await conn.connect();
      }());
    } else {
      _toast(AppStrings.t('local_port_saved'));
    }
  }

  /// 本地代理端口（默认 2080），不能与 Clash API 端口相同
  Future<void> _pickLocalPort() async {
    final cur = (_s['localPort'] as num?)?.toInt() ?? 2080;
    final clash = (_s['clashApiPort'] as num?)?.toInt() ?? 9090;
    final p = await _askPort(AppStrings.t('settings_local_port'), '2080', cur,
        AppStrings.t('local_port_invalid'), clash);
    if (p == null) return;
    await _applyPortChange('localPort', p);
  }

  /// Clash API 管理端口（默认 9090），不能与本地代理端口相同
  Future<void> _pickClashApiPort() async {
    final cur = (_s['clashApiPort'] as num?)?.toInt() ?? 9090;
    final local = (_s['localPort'] as num?)?.toInt() ?? 2080;
    final p = await _askPort(AppStrings.t('settings_clash_api_port'), '9090', cur,
        AppStrings.t('clash_api_port_invalid'), local,
        helper: AppStrings.t('settings_clash_api_port_desc'));
    if (p == null) return;
    await _applyPortChange('clashApiPort', p);
  }

  /// 测速地址（默认谷歌 204；网络环境特殊时可改）
  Future<void> _pickTestUrl() async {
    final cur = _s['testUrl']?.toString() ?? ConnectionController.defaultTestUrl;
    final v = await _askText(
      title: AppStrings.t('settings_test_url'),
      initial: cur,
      hint: ConnectionController.defaultTestUrl,
      helper: AppStrings.t('settings_test_url_desc'),
      keyboardType: TextInputType.url,
      validate: (raw) {
        final u = raw.trim();
        return (u.startsWith('http://') || u.startsWith('https://'))
            ? null
            : AppStrings.t('test_url_invalid');
      },
    );
    if (v == null) return; // 取消
    // _set 内部已同步到连接控制器（applySettings 读取 testUrl）
    await _set('testUrl', v.trim());
  }

  /// 订阅自定义 User-Agent：部分机场按 UA 返回不同客户端格式，留一个自救入口。
  /// 留空 = 使用默认 `MoneyFly/<版本>`。
  Future<void> _pickSubscribeUa() async {
    final cur = _s['subscribeUserAgent']?.toString() ?? '';
    final ctrl = TextEditingController(text: cur);
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('settings_subscribe_ua'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: MFColors.txt),
          decoration: mfInput(
            hint: 'clash-verge/v2.0.0',
            helper: AppStrings.t('settings_subscribe_ua_desc'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.t('cancel_text')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text(AppStrings.t('save'),
                style: TextStyle(color: MFColors.brandLight)),
          ),
        ],
      ),
    );
    if (v == null) return; // 取消
    await _set('subscribeUserAgent', v); // 空串 = 回默认 UA
  }

  /// 测速地址行展示：取 host，避免超长 URL 挤爆行
  String _testUrlHost() {
    final u = _s['testUrl']?.toString() ?? ConnectionController.defaultTestUrl;
    final host = Uri.tryParse(u)?.host;
    return (host != null && host.isNotEmpty) ? host : u;
  }

  /// 生效的主 DNS 列表：dnsNameservers（新，主列表）> dns（旧单值兼容）> 默认
  List<String> _dnsList() {
    final stored = _s['dnsNameservers'];
    if (stored is List && stored.isNotEmpty) {
      return List<String>.from(stored.whereType<String>());
    }
    final legacy = _s['dns']?.toString().trim() ?? '';
    if (legacy.isNotEmpty && legacy != '223.5.5.5') return [legacy];
    return List<String>.from(_defaultDnsServers);
  }

  /// fake-ip 过滤追加域名列表（SettingsStore['fakeIpFilterExtra']）
  List<String> _fakeIpExtra() {
    final l = _s['fakeIpFilterExtra'];
    return l is List
        ? List<String>.from(l.whereType<String>())
        : const <String>[];
  }

  /// 逗号（半/全角）、换行分隔的 DNS 文本 → 去空白、去重、保序的列表
  static List<String> _splitServerText(String v) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in v.split(RegExp(r'[,，\r\n]+'))) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  bool _isIpv4(String s) {
    final parts = s.split('.');
    if (parts.length != 4) return false;
    for (final o in parts) {
      if (o.isEmpty) return false;
      if (o.length > 1 && o.startsWith('0')) return false;
      final n = int.tryParse(o);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  /// 主机名（单/多标签，可带结尾点；DNS 域名/DoH host 都走这里）
  bool _isHostname(String s) {
    if (s.isEmpty || s.length > 253 || s.contains('..')) return false;
    return RegExp(
            r'^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.?$')
        .hasMatch(s);
  }

  /// 单个 DNS 服务器是否合法：IPv4 / IPv6 / 域名 / DoH·DoT 带协议 URL
  bool _isValidDnsServer(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    // https://dns.alidns.com/dns-query、tls://dns.google 等带协议地址
    if (t.contains('://')) {
      final u = Uri.tryParse(t);
      return u != null && u.host.isNotEmpty;
    }
    if (t.contains(':')) {
      // IPv6（可带 [ ]）
      final v6 = t.replaceAll('[', '').replaceAll(']', '');
      if (RegExp(r'^[0-9a-fA-F:]+$').hasMatch(v6) &&
          (v6.contains('::') || ':'.allMatches(v6).length >= 2)) {
        return true;
      }
      return false; // host:port 形式的内核 nameserver 不支持
    }
    return _isIpv4(t) || _isHostname(t);
  }

  /// 主 DNS 列表编辑（逗号/换行分隔文本），合法才保存
  Future<void> _pickDnsList() async {
    final v = await _askText(
      title: AppStrings.t('settings_dns'),
      initial: _dnsList().join(', '),
      hint: AppStrings.t('dns_list_hint'),
      keyboardType: TextInputType.url,
      minLines: 2,
      maxLines: 5,
      validate: (raw) {
        final servers = _splitServerText(raw);
        if (servers.isEmpty) return AppStrings.t('dns_list_required');
        for (var i = 0; i < servers.length; i++) {
          if (!_isValidDnsServer(servers[i])) {
            return AppStrings.t('dns_list_invalid', {'n': '${i + 1}'});
          }
        }
        return null;
      },
    );
    if (v == null) return; // 取消
    await _set('dnsNameservers', _splitServerText(v));
  }

  /// 规范化 fake-ip 过滤条目：小写，可选 `*.` 前缀，须为合法域名
  String? _normalizeFakeIpPattern(String raw) {
    var p = raw.trim().toLowerCase();
    var wildcard = false;
    if (p.startsWith('*.')) {
      wildcard = true;
      p = p.substring(2);
    }
    if (p.startsWith('.')) p = p.substring(1);
    if (!_isHostname(p)) return null;
    return wildcard ? '*.$p' : p;
  }

  /// fake-ip 过滤追加域名编辑（每行一个；域名保留真实解析）
  Future<void> _pickFakeIpFilter() async {
    final v = await _askText(
      title: AppStrings.t('settings_fakeip_extra'),
      initial: _fakeIpExtra().join('\n'),
      hint: AppStrings.t('fakeip_extra_hint'),
      keyboardType: TextInputType.multiline,
      minLines: 3,
      maxLines: 6,
      style: TextStyle(color: MFColors.txt, fontSize: 13),
      validate: (raw) {
        final items = _splitServerText(raw);
        for (var i = 0; i < items.length; i++) {
          if (_normalizeFakeIpPattern(items[i]) == null) {
            return AppStrings.t('fakeip_invalid', {'line': '${i + 1}'});
          }
        }
        return null; // 全部清空 = 合法（允许用户清掉整个列表）
      },
    );
    if (v == null) return; // 取消
    final out = <String>[];
    for (final it in _splitServerText(v)) {
      final norm = _normalizeFakeIpPattern(it);
      if (norm != null) out.add(norm);
    }
    await _set('fakeIpFilterExtra', out);
  }

  Future<void> _pickTunMode() async {
    final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    final options = [AppStrings.t('tun_auto'), AppStrings.t('tun_force'), AppStrings.t('tun_off')];
    // 当前模式（与行内展示同一份映射）→ 该行打勾，用户能看出现在选的是哪个
    final currentLabel = _tunModeValue();
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('tun_title'), style: TextStyle(fontSize: 15)),
        children: [
          if (isDesktop)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: MFColors.amber.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: MFColors.amber.withValues(alpha: .3)),
                ),
                child: Text(
                  Platform.isWindows
                      ? AppStrings.t('tun_win_hint')
                      : AppStrings.t('tun_mac_hint'),
                  style: TextStyle(fontSize: 11, color: MFColors.txt2, height: 1.6),
                ),
              ),
            ),
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Row(
                children: [
                  if (o == currentLabel) ...[
                    Icon(Icons.check, size: 16, color: MFColors.brandLight),
                    const SizedBox(width: 8),
                  ],
                  // 标签/说明都要能压缩：Row 里非 flex 的 Text 按无限宽测量，
                  // 窄对话框（380 最小窗口）下会直接 RenderFlex overflow
                  Expanded(
                    child: Text(o,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      o == AppStrings.t('tun_off') ? AppStrings.t('tun_only_proxy') : (o == AppStrings.t('tun_force') ? AppStrings.t('tun_full_intercept') : AppStrings.t('tun_dual')),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(fontSize: 10.5, color: MFColors.txt3),
                    ),
                  ),
                ],
              ),
            ),
          // UDP/游戏提示：系统代理（HTTP）不承载 UDP，Steam/游戏需 TUN
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: MFColors.amber.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: MFColors.amber.withValues(alpha: .3)),
              ),
              child: Text(
                AppStrings.t('tun_game_tip'),
                style: TextStyle(fontSize: 11, color: MFColors.txt2, height: 1.6),
              ),
            ),
          ),
        ],
      ),
    );
    if (v != null) {
      final mode = v == AppStrings.t('tun_force') ? 'force' : (v == AppStrings.t('tun_off') ? 'off' : 'auto');
      await _set('tunMode', mode);
      // TUN 是**建连期参数**：内核只在启动时读它。旧实现只落盘、不重连也不提示，
      // 用户切到 TUN 后当前连接其实还是系统代理（或反之），界面却毫无反馈。
      final conn = ConnectionController.instance;
      if (conn.status == ConnStatus.connected) {
        _toast(AppStrings.t('setting_reconnect_applied'));
        unawaited(() async {
          await conn.disconnect();
          await conn.connect();
        }());
      } else {
        _toast(AppStrings.t('setting_saved_next_connect'));
      }
    }
  }

  /// 语言切换：简体中文 / English（立即生效）
  Future<void> _pickLanguage() async {
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        // 标题必须走 l10n：项目默认中文，旧实现写死英文 'Language'
        title: Text(AppStrings.t('settings_language'), style: TextStyle(fontSize: 15)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'zh'),
            child: Row(children: [
              Text(AppStrings.t('zh'), style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
              if (AppStrings.lang == 'zh') ...[
                const Spacer(),
                Icon(Icons.check, size: 16, color: MFColors.brandLight),
              ],
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'en'),
            child: Row(children: [
              Text(AppStrings.t('en'), style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
              if (AppStrings.lang == 'en') ...[
                const Spacer(),
                Icon(Icons.check, size: 16, color: MFColors.brandLight),
              ],
            ]),
          ),
        ],
      ),
    );
    if (v != null && v != AppStrings.lang) {
      await LocaleController.instance.setLang(v);
    }
  }


  /// 清除本地数据（订阅配置缓存 / 节点 / 运行日志）：
  /// 断开连接 → 清内存与磁盘订阅缓存 → 清日志。保留登录状态，
  /// 下次进入节点页会重新拉取最新订阅（配合到期/禁用后强制刷新，
  /// 避免旧配置残留；卸载前清空也用它）。
  Future<void> _clearLocalData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('settings_clear_data'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(AppStrings.t('clear_data_confirm'),
            style: TextStyle(fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('confirm'),
                style: TextStyle(color: MFColors.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final conn = ConnectionController.instance;
      if (conn.status == ConnStatus.connected ||
          conn.status == ConnStatus.connecting ||
          conn.status == ConnStatus.reconnecting) {
        await conn.disconnect();
      }
      // 清订阅缓存（内存 + 磁盘）
      SubscriptionService.instance.clearCache();
      // 清内存节点展示（下次进入节点页/首页会自动重新拉取）
      await conn.loadNodes(const []);
      // 清运行日志
      await AppLog.clear();
      if (mounted) _toast(AppStrings.t('clear_data_done'));
    } catch (_) {
      if (mounted) _toast(AppStrings.t('clear_data_failed'));
    }
  }

  /// 软件升级：读后端软件库 → 比对版本 → 弹更新对话框
  String _closeActionLabel() {
    return switch (_s['closeAction']?.toString()) {
      'hide' => AppStrings.t('close_action_hide'),
      'quit' => AppStrings.t('close_action_quit'),
      _ => AppStrings.t('close_action_ask'),
    };
  }

  Future<void> _pickCloseAction() async {
    final labels = <String, String>{
      AppStrings.t('close_action_ask'): 'ask',
      AppStrings.t('close_action_hide'): 'hide',
      AppStrings.t('close_action_quit'): 'quit',
    };
    await _picker(labels.keys.toList(), (label) {
      final v = labels[label];
      if (v != null) unawaited(_set('closeAction', v));
    }, current: _closeActionLabel());
  }

  /// 单选列表弹窗。 [current] 传当前值 → 该行右侧显示勾选（审计 P2：本文件的
  /// 选择器都不标当前值，而节点页 / 内核页都有，用户看不出现在选的是哪个）。
  Future<void> _picker(List<String> options, ValueChanged<String> onSelected,
      {String? current}) async {
    final v = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('pick_option'), style: TextStyle(fontSize: 15)),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Row(
                children: [
                  // Expanded + 省略号：选项文案在窄对话框里必须能压缩，否则
                  // Row 内无界测量的 Text 会直接溢出（Ahem 测试字体更宽）
                  Expanded(
                    child: Text(o,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, color: MFColors.txt)),
                  ),
                  if (o == current) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check, size: 16, color: MFColors.brandLight),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
    if (v != null) onSelected(v);
  }

void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 对话框输入框装饰：错误常驻在输入框下方（审计 P1：旧实现先 pop 再校验，
/// 错误只能靠 4 秒 snackbar 闪一下、输入还被丢掉）。
/// 现在 [mfInput] 自己就支持 `errorText`（含错误边框），不再需要就地补一份。
InputDecoration _mfInputErr({String? hint, String? helper, String? error}) =>
    mfInput(hint: hint, helper: helper, errorText: error);
