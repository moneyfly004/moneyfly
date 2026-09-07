import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 设备服务：列表（全量分页拉取）/ 删除 / 备注。
///
/// 列表：后端 /subscriptions/devices 默认一页 10 条，客户端不传分页参数时
/// 只会拿到前 10 台 → 「设备管理只显示部分设备」。这里显式分页并循环取完
/// 全部页（设备上限通常是个位数~几十台，一次拉全对服务器无压力）。
class DeviceService {
  DeviceService._();
  static final DeviceService instance = DeviceService._();

  /// 后端单页上限（utils.ParsePagination size 最大 100）
  static const _pageSize = 100;

  Future<List<DeviceInfo>> list() async {
    final all = <DeviceInfo>[];
    var page = 1;
    while (true) {
      // /subscriptions/devices 返回 {devices:[...], total, page, size}，
      // 且 location 有真实地理位置
      final data = await ApiClient.instance.get(Endpoints.subscriptionsDevices,
          query: {'page': '$page', 'size': '$_pageSize'});
      final list = data is List ? data : (data is Map ? data['devices'] : null);
      if (list is! List) break;
      all.addAll(list
          .map((e) => DeviceInfo.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList());
      final total = data is Map ? (data['total'] as num?)?.toInt() ?? 0 : 0;
      if (total <= 0 || all.length >= total) break;
      page++;
    }
    return all;
  }

  Future<void> delete(int deviceId) async {
    await ApiClient.instance.delete('${Endpoints.devices}/$deviceId');
  }

  /// 更新设备备注（后端 PUT /subscriptions/devices/:id/remark；空串=清空）
  Future<void> updateRemark(int deviceId, String remark) async {
    await ApiClient.instance.put(
      '${Endpoints.subscriptionsDevices}/$deviceId/remark',
      data: {'remark': remark},
    );
  }
}
