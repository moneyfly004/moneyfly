import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/proxy/proxy_core_cli.dart';
import '../../core/services/app_log.dart';
import '../../core/services/settings_store.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// 日志中心：两个 Tab
/// - 内核日志（实时）：mihomo 引擎输出 —— 引擎级排障（连不上/打不开网页）
/// - 运行日志：App 自身记录 —— 应用流程排障（没自动连/订阅没更新等）
class LogCenterPage extends StatelessWidget {
  const LogCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              onPressed: () => Navigator.pop(context)),
          title: Text(AppStrings.t('log_center_title')),
          bottom: TabBar(
            indicatorColor: MFColors.brand,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: MFColors.brand,
            unselectedLabelColor: MFColors.txt3,
            labelStyle: const TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 13.5),
            tabs: [
              Tab(text: AppStrings.t('settings_kernel_log')),
              Tab(text: AppStrings.t('settings_log')),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _KernelLogTab(),
            _AppLogTab(),
          ],
        ),
      ),
    );
  }
}

// ================= 内核日志（实时）Tab =================

class _KernelLogTab extends StatefulWidget {
  const _KernelLogTab();

  @override
  State<_KernelLogTab> createState() => _KernelLogTabState();
}

class _KernelLogTabState extends State<_KernelLogTab>
    with AutomaticKeepAliveClientMixin {
  final List<String> _lines = [];
  static const _maxLines = 600;

  StreamSubscription<String>? _streamSub;
  Timer? _pollTimer;
  String _level = 'warning';

  static const _levels = ['debug', 'info', 'warning', 'error', 'silent'];

  // Android 轮询状态：_pollBusy 防止上一轮（含 drain 续读）未结束时定时器重入；
  // _cursorReset 仅首次进入页面时为 true，让第一轮请求原生侧回放「最近行」建立
  // 基线（后续增量）。因 Tab 走 keep-alive，状态不销毁，重置只发生在首次打开。
  bool _pollBusy = false;
  bool _cursorReset = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    SettingsStore.instance.load().then((s) {
      if (!mounted) return;
      final lv = s['kernelLogLevel']?.toString() ?? 'warning';
      setState(() => _level = _levels.contains(lv) ? lv : 'warning');
    });
    if (Platform.isAndroid) {
      // 原生侧自上次读取位置起只回传增量行，且返回内容经 hasMore 分片追平，
      // 因此轮询间隔可放宽到 1200ms 而不丢日志。
      _pollTimer = Timer.periodic(
          const Duration(milliseconds: 1200), (_) => _pollAndroid());
    } else {
      _lines.addAll(ProxyCoreCli.logTailSnapshot());
      _trim();
      _streamSub = ProxyCoreCli.kernelLogStream.stream.listen(_append);
    }
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  /// Android 轮询：拉「增量」日志。
  ///
  /// 原生侧只回传自上次读取以来新增的完整行（首次/重进页面先回放最近若干行基线），
  /// 并用 hasMore 告知本批是否截断 —— 截断时立即续读（每轮最多 8 片）尽量追平；
  /// 整帧累计的所有增量行在末尾合并成一次 setState 追加，避免逐行刷新越拉越卡。
  Future<void> _pollAndroid() async {
    if (_pollBusy) return;
    _pollBusy = true;
    try {
      const ch = MethodChannel('top.moneyfly/vpn_core');
      final merged = <String>[];
      for (var round = 0; round < 8; round++) {
        final res = await ch.invokeMethod<Map<dynamic, dynamic>>(
          'fetchKernelLogs',
          <String, dynamic>{'incremental': true, 'reset': _cursorReset},
        );
        _cursorReset = false;
        if (res == null) break;
        final log = res['log'];
        if (log is String && log.isNotEmpty) {
          for (final l in log.split('\n')) {
            if (l.trim().isNotEmpty) merged.add(l);
          }
        }
        if (res['hasMore'] != true) break;
      }
      if (merged.isNotEmpty) _appendLines(merged);
    } catch (_) {
      // 通道暂不可用等偶发错误：静默跳过，等下一个轮询周期重试
    } finally {
      _pollBusy = false;
    }
  }

  /// 一批行（可能跨多个 drain 轮次合并）一次性追加并 setState，同时保留行数上限
  void _appendLines(List<String> lines) {
    if (!mounted || lines.isEmpty) return;
    setState(() {
      _lines.addAll(lines);
      _trim();
    });
  }

  /// 内核日志行按级别着色:debug=灰蓝 info=正文 warning=琥珀 error=红
  Color _lineColor(String line) {
    final l = line.toLowerCase();
    if (l.contains('level=error') || l.contains('panic') ||
        l.contains('fatal') || l.contains('exception')) {
      return const Color(0xFFFF6B6B);
    }
    if (l.contains('level=warning') || l.contains('warn')) {
      return const Color(0xFFE0A93C);
    }
    if (l.contains('level=debug')) {
      return const Color(0xFF8FB4E8);
    }
    return MFColors.txt2;
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      _trim();
    });
  }

  void _trim() {
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
  }

  Future<void> _setLevel(String lv) async {
    setState(() => _level = lv);
    await ConnectionController.instance.setKernelLogLevel(lv);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final running = ConnectionController.instance.status == ConnStatus.connected;
    return Column(
      children: [
        // 工具栏：级别切换 + 连接状态 + 复制/清空
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 4),
          child: Row(
            children: [
              Text(AppStrings.t('kernel_log_level'),
                  style: TextStyle(fontSize: 11, color: MFColors.txt3)),
              const SizedBox(width: 8),
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final lv in _levels)
                        GestureDetector(
                          onTap: () => _setLevel(lv),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              gradient: _level == lv
                                  ? MFColors.brandGradient
                                  : null,
                              color: _level == lv ? null : MFColors.card,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: _level == lv
                                      ? Colors.transparent
                                      : MFColors.line),
                            ),
                            child: Text(
                              lv.toUpperCase(),
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: _level == lv
                                    ? Colors.white
                                    : MFColors.txt2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: running ? MFColors.green : MFColors.txt3,
                ),
              ),
              const SizedBox(width: 4),
              Text(running ? '' : AppStrings.t('kernel_stopped'),
                  style: TextStyle(
                      fontSize: 10,
                      color: running ? MFColors.green : MFColors.txt3)),
              IconButton(
                icon: const Icon(Icons.copy, size: 17),
                tooltip: AppStrings.t('copy'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _copyAll(),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: AppStrings.t('clear_log'),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(_lines.clear),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: MFColors.line),
        // 日志区（reverse：最新在底部并自动贴底）
        Expanded(
          child: _lines.isEmpty
              ? Center(
                  child: Text(AppStrings.t('kernel_log_empty'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: MFColors.txt3, height: 1.7)))
              : ListView.builder(
                  reverse: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  itemCount: _lines.length,
                  itemBuilder: (context, i) {
                    final line = _lines[_lines.length - 1 - i];
                    final lc = _lineColor(line);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: SelectableText(
                        line,
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.55,
                          color: lc,
                          fontFamily: kNumFont,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _copyAll() async {
    final text = _lines.join('\n');
    if (text.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(
      content: Text(AppStrings.t('kernel_log_copied'),
          style: const TextStyle(fontSize: 13)),
      backgroundColor: MFColors.card2,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 1),
    ));
  }
}

// ================= App 运行日志 Tab =================

class _AppLogTab extends StatefulWidget {
  const _AppLogTab();

  @override
  State<_AppLogTab> createState() => _AppLogTabState();
}

class _AppLogTabState extends State<_AppLogTab>
    with AutomaticKeepAliveClientMixin {
  List<String> _lines = const [];
  bool _loading = true;
  bool _filterError = false;

  @override
  bool get wantKeepAlive => true;

  static bool _isErrorLine(String line) =>
      line.contains('[ERROR]') || line.toLowerCase().contains('level=error');

  Color _lineColor(String line) =>
      _isErrorLine(line) ? const Color(0xFFFF6B6B) : MFColors.txt2;

  List<String> get _visible =>
      _filterError ? _lines.where(_isErrorLine).toList() : _lines;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    var lines = const <String>[];
    try {
      final content = await AppLog.read();
      final raw = content.split('\n');
      // 文件以换行结尾，去掉末尾的空串（避免渲染出多余空行）
      lines = raw.isNotEmpty && raw.last.isEmpty
          ? raw.sublist(0, raw.length - 1)
          : raw;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _lines = lines;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: Text(AppStrings.t('clear_log'),
            style: const TextStyle(fontSize: 15)),
        content: Text(AppStrings.t('log_clear_confirm'),
            style: TextStyle(fontSize: 13, color: MFColors.txt2)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppStrings.t('cancel_text'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('clear_log'),
                style: TextStyle(color: MFColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppLog.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(AppStrings.t('settings_log_desc'),
                    style: TextStyle(fontSize: 10.5, color: MFColors.txt3)),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 17),
                tooltip: AppStrings.t('refresh'),
                visualDensity: VisualDensity.compact,
                onPressed: _load,
              ),
              IconButton(
                icon: Icon(
                    _filterError ? Icons.filter_alt : Icons.filter_alt_outlined,
                    size: 17),
                tooltip: AppStrings.t('log_only_errors'),
                color: _filterError ? MFColors.brandLight : null,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _filterError = !_filterError),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 17),
                tooltip: AppStrings.t('copy'),
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  final visible = _visible;
                  if (visible.isEmpty) return;
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(
                      ClipboardData(text: visible.join('\n')));
                  messenger.showSnackBar(SnackBar(
                    content: Text(AppStrings.t('kernel_log_copied'),
                        style: const TextStyle(fontSize: 13)),
                    backgroundColor: MFColors.card2,
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 1),
                  ));
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: AppStrings.t('clear_log'),
                visualDensity: VisualDensity.compact,
                onPressed: _clear,
              ),
            ],
          ),
        ),
        Divider(height: 1, color: MFColors.line),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: MFColors.brand))
              : _lines.isEmpty
                  ? Center(
                      child: Text(AppStrings.t('log_empty'),
                          style: TextStyle(
                              fontSize: 12, color: MFColors.txt3)))
                  : _visible.isEmpty
                      ? Center(
                          child: Text(AppStrings.t('log_no_errors'),
                              style: TextStyle(
                                  fontSize: 12, color: MFColors.txt3)))
                      : ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          itemCount: _visible.length,
                          itemBuilder: (context, i) {
                            final line = _visible[_visible.length - 1 - i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 1),
                              child: SelectableText(
                                line,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  height: 1.6,
                                  color: _lineColor(line),
                                  fontFamily: kNumFont,
                                ),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
