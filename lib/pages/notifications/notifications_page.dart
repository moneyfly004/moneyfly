import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import '../../core/services/notification_service.dart';
import '../../theme/app_theme.dart';

/// 通知中心：列表 / 已读 / 全部已读 / 删除
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  List<AppNotification> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final list = await NotificationService.instance.list();
      if (mounted) setState(() => _items = list);
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markRead(AppNotification n) async {
    if (n.isRead) return;
    try {
      await NotificationService.instance.markRead(n.id);
      await _load();
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  Future<void> _markAll() async {
    try {
      await NotificationService.instance.markAllRead();
      await _load();
      if (mounted) _toast('已全部标记为已读');
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  Future<void> _delete(AppNotification n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: MFColors.card2,
        title: const Text('删除通知', style: TextStyle(fontSize: 16)),
        content: const Text('确定删除这条通知吗？', style: TextStyle(fontSize: 13.5, color: MFColors.txt2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: MFColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await NotificationService.instance.delete(n.id);
      await _load();
    } catch (e) {
      if (mounted) _toast(ApiClient.errorMsg(e));
    }
  }

  /// 兼容后端两种时间格式：RFC3339(带T) 与 "YYYY-MM-DD HH:mm:ss"
  static String _formatTime(String raw) {
    if (raw.isEmpty) return '';
    if (raw.contains('T')) {
      final dt = DateTime.tryParse(raw);
      if (dt != null) {
        final m = dt.month.toString().padLeft(2, '0');
        final d = dt.day.toString().padLeft(2, '0');
        final h = dt.hour.toString().padLeft(2, '0');
        final min = dt.minute.toString().padLeft(2, '0');
        return '$m-$d $h:$min';
      }
    }
    return raw.length > 16 ? raw.substring(5, 16) : raw;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18), onPressed: () => Navigator.pop(context)),
        title: const Text('通知中心'),
        actions: [
          if (_items.any((n) => !n.isRead))
            TextButton(onPressed: _markAll, child: const Text('全部已读', style: TextStyle(color: MFColors.brandLight))),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: MFColors.brand))
            : _items.isEmpty
                ? const Center(child: Text('暂无通知', style: TextStyle(fontSize: 14, color: MFColors.txt3)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final n = _items[i];
                      return GestureDetector(
                        onTap: () => _markRead(n),
                        onLongPress: () => _delete(n),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: n.isRead ? MFColors.card : MFColors.brand.withValues(alpha: .07),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                                color: n.isRead ? MFColors.line : MFColors.brand.withValues(alpha: .35)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (!n.isRead) ...[
                                    Container(
                                      width: 7, height: 7,
                                      decoration: const BoxDecoration(color: MFColors.brandLight, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 7),
                                  ],
                                  Expanded(
                                    child: Text(n.title,
                                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600,
                                            color: n.isRead ? MFColors.txt2 : MFColors.txt)),
                                  ),
                                  Text(_formatTime(n.createdAt),
                                      style: const TextStyle(fontSize: 10, color: MFColors.txt3, fontFamily: kNumFont)),
                                ],
                              ),
                              if (n.content.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(n.content,
                                    style: const TextStyle(fontSize: 12.5, color: MFColors.txt2, height: 1.6)),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
