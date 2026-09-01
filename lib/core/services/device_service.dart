import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 设备服务：列表 / 备注 / 删除
class DeviceService {
  DeviceService._();
  static final DeviceService instance = DeviceService._();

  Future<List<DeviceInfo>> list() async {
    final data = await ApiClient.instance.get(Endpoints.devices);
    if (data is! List) return [];
    return data.map((e) => DeviceInfo.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// 修改备注（后端限制 ≤200 字符，空串 = 清空）
  Future<void> updateRemark(int deviceId, String remark) async {
    await ApiClient.instance.put(
      '${Endpoints.subscriptionsDevices}/$deviceId/remark',
      data: {'remark': remark},
    );
  }

  Future<void> delete(int deviceId) async {
    await ApiClient.instance.delete('${Endpoints.devices}/$deviceId');
  }
}
