import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/proxy/proxy_core.dart';
import '../../core/proxy/proxy_core_cli.dart';
import '../../core/services/settings_store.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';

/// 内核日志实时页：连接时实时滚动显示 mihomo 内核日志。
/// - 桌面：订阅 ProxyCoreCli.kernelLogStream（进程 stdout 每行推送）
/// - Android：轮询 libmihomo.Logs()（wrapper 环形缓冲增量）
/// 顶部可切换日志级别（debug/info/warning），连接中即时热更。
class KernelLogPage extends StatefulWidget {
  const KernelLogPage({super.key});

  @override
  State<KernelLogPage> createState() => _KernelLogPageState();
}

class _KernelLogPageState extends State<KernelLogPage> {
  final List<String> _lines = [];
  static const _maxLines = 600;

  StreamSubscription<String>? _streamSub;
  Timer? _pollTimer;
  String _level = 'warning';

  static const _levels = ['debug', 'info', 'warning'];

  @override
  void initState() {
    super.initState();
    SettingsStore.instance.load().then((s) {
      if (!mounted) return;
      final lv = s['kernelLogLevel']?.toString() ?? 'warning';
      setState(() => _level = _levels.contains(lv) ? lv : 'warning');
    });
    if (Platform.isAndroid) {
      _pollTimer = Timer.periodic(const Duration(milliseconds: 600), (_) => _pollAndroid());
    } else {
      // 桌面：先加载历史，再订阅实时流
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

  Future<void> _pollAndroid() async {
    try {
      const ch = MethodChannel('top.moneyfly/vpn_core');
      final logs = await ch.invokeMethod<String>('fetchKernelLogs') ?? '';
      if (logs.isNotEmpty) {
        for (final l in logs.split('\n')) {
          if (l.trim().isNotEmpty) _append(l);
        }
      }
    } catch (_) {}
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
    final running = ConnectionController.instance.status == ConnStatus.connected;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => Navigator.pop(context)),
        title: Text(AppStrings.t('kernel_log_title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: AppStrings.t('copy'),
            onPressed: () async {
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
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 19),
            tooltip: AppStrings.t('clear_log'),
            onPressed: () => setState(_lines.clear),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 级别切换 + 状态
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Row(
                children: [
                  Text(AppStrings.t('kernel_log_level'),
                      style: TextStyle(fontSize: 11, color: MFColors.txt3)),
                  const SizedBox(width: 8),
                  for (final lv in _levels) ...[
                    GestureDetector(
                      onTap: () => _setLevel(lv),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          gradient: _level == lv ? MFColors.brandGradient : null,
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
                            color: _level == lv ? Colors.white : MFColors.txt2,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: running ? MFColors.green : MFColors.txt3,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(running ? '●' : AppStrings.t('kernel_stopped'),
                      style: TextStyle(
                          fontSize: 10,
                          color: running ? MFColors.green : MFColors.txt3)),
                ],
              ),
            ),
            Divider(height: 1, color: MFColors.line),
            // 日志区（reverse：最新行在底部并自动贴底）
            Expanded(
              child: _lines.isEmpty
                  ? Center(
                      child: Text(AppStrings.t('kernel_log_empty'),
                          style: TextStyle(
                              fontSize: 12, color: MFColors.txt3)))
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      itemCount: _lines.length,
                      itemBuilder: (context, i) {
                        final line = _lines[_lines.length - 1 - i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: SelectableText(
                            line,
                            style: TextStyle(
                              fontSize: 10.5,
                              height: 1.55,
                              color: MFColors.txt2,
                              fontFamily: kNumFont,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
