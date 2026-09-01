import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 设备服务：列表 / 删除（后端 /devices 仅支持 GET 与 DELETE，无备注接口）
class DeviceService {
  DeviceService._();
  static final DeviceService instance = DeviceService._();

  Future<List<DeviceInfo>> list() async {
    final data = await ApiClient.instance.get(Endpoints.devices);
    if (data is! List) return [];
    return data.map((e) => DeviceInfo.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<void> delete(int deviceId) async {
    await ApiClient.instance.delete('${Endpoints.devices}/$deviceId');
  }
}
