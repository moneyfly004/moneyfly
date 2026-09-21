import 'package:dio/dio.dart';

import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 设备服务：列表（全量分页拉取）/ 删除 / 备注。
///
/// 列表：后端 /subscriptions/devices 默认一页 10 条，客户端不传分页参数时
/// 只会拿到前 10 台 → 「设备管理只显示部分设备」。这里显式分页并循环取完
/// 全部页（设备上限通常是个位数~几十台，一次拉全对服务器无压力）。
/// 自助「重新绑定本机」的结果
enum DeviceRebindResult {
  /// 已恢复（或本机本来正常）→ 调用方刷新订阅即可
  ok,

  /// 设备名额已满 → 引导去设备管理删闲置设备
  deviceLimit,

  /// 后端还没上这个接口（404）→ 回退到「重新登录」
  unsupported,

  /// 其它失败
  failed,
}

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
  /// 自助恢复：把被「踢下线」的本机重新登记回设备列表。
  ///
  /// 场景：用户删掉本机设备（删除 = 软删 + 踢下线）后，后端对该设备拉订阅一律
  /// 403「此设备已被移除并踢下线,如需继续使用请重新登录或联系客服」——
  /// 此前后端没有任何路径能清掉这个状态，用户被永久锁死（只能找客服改库）。
  /// 现在后端提供了本接口：token 仍然有效（被踢只影响订阅接口），
  /// 一次调用即可恢复，不必重新输入密码。
  Future<DeviceRebindResult> rebindCurrent() async {
    try {
      await ApiClient.instance.post(Endpoints.devicesRebind);
      return DeviceRebindResult.ok;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final msg = ApiClient.errorMsg(e);
      if (code == 403 && (msg.contains('名额') || msg.contains('上限'))) {
        return DeviceRebindResult.deviceLimit;
      }
      if (code == 404) return DeviceRebindResult.unsupported;
      return DeviceRebindResult.failed;
    } catch (_) {
      return DeviceRebindResult.failed;
    }
  }

  Future<void> updateRemark(int deviceId, String remark) async {
    await ApiClient.instance.put(
      '${Endpoints.subscriptionsDevices}/$deviceId/remark',
      data: {'remark': remark},
    );
  }
}
