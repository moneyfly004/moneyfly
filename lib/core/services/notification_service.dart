import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 通知服务
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  Future<List<AppNotification>> list() async {
    final data = await ApiClient.instance.get(Endpoints.notifications);
    if (data is! List) return [];
    return data.map((e) => AppNotification.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<int> unreadCount() async {
    final data = await ApiClient.instance.get(Endpoints.notificationsUnread);
    if (data is Map && data['count'] != null) return (data['count'] as num).toInt();
    return 0;
  }

  Future<void> markRead(int id) async {
    await ApiClient.instance.put('${Endpoints.notifications}/$id/read');
  }

  Future<void> markAllRead() async {
    await ApiClient.instance.put('${Endpoints.notifications}/read-all');
  }

  Future<void> delete(int id) async {
    await ApiClient.instance.delete('${Endpoints.notifications}/$id');
  }
}
