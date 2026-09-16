/// TUN 启动失败的判定与分类（纯 Dart，无 Flutter 依赖，可单测）。
///
/// 为什么需要它：mihomo 的 TUN 起不来时**不会退出、也不会让 Clash API 报错**，
/// 只在日志里打一行 error 就继续跑 → App 若只看 API 200，就会「显示已连接、
/// 零流量、零报错」（force 模式尤其致命）。所以必须读内核日志判定。
///
/// 但判定不能粗：旧实现是「行里同时含 `tun` 和 `error`/`failed`」，而 mihomo
/// 日志里有一批**正常告警与转发期噪音**同样命中，会直接把一条本来好好的连接
/// 判死、还提示用户「请以管理员身份运行」：
///   - `[TUN] Auto detect interface for <名> failed, return '<invalid>' …`
///     （auto-detect-interface 在多虚拟网卡 / Hyper-V / 某些 VPN 环境下探不到
///      出口接口，属正常告警，TUN 本身是好的）
///   - `[TUN] default interface changed/lost by monitor …`（网卡切换监控，正常）
///   - `[TUN] Tun adapter listening at: …`、`[TUN] use tun name …`（成功日志）
///   - `error writing to TUN device` / `Failed to read packet from TUN device`
///     （数据面转发错误，连接期偶发，不代表 TUN 没起来）
///
/// 因此这里只认**真正的启动失败**串（见 [_fatalMarkers]），再按原因分类，
/// 让上层能给出可执行的提示（提权 / 网卡冲突 / 驱动被拦），而不是一句
/// 万能的「请以管理员身份运行」。
library;

/// TUN 启动失败的原因分类
enum TunStartFailure {
  /// 没有失败（含「只有告警」的情况）
  none,

  /// 权限不足：Windows 未以管理员运行 / macOS 未以 root 运行
  privilege,

  /// 虚拟网卡已存在或被占用（同名网卡残留、上次异常退出留下的适配器）
  adapterBusy,

  /// 虚拟网卡驱动 / DLL 无法加载（多被安全软件拦截）
  driver,

  /// 起来了但原因无法归类
  unknown,
}

/// 真正的「TUN 没起来」标记（sing-tun 的启动失败出口）。
/// 必须精确：多一个宽泛词就会把正常连接判死。
const _fatalMarkers = <String>[
  'start tun listening error',
  'start tun interface timeout',
];

/// 权限类特征（Windows ERROR_ACCESS_DENIED / POSIX EPERM）
const _privilegeMarkers = <String>[
  'access is denied',
  'access denied',
  'permission denied',
  'operation not permitted',
  'requires elevation',
  'administrator',
  'run as root',
];

/// 网卡冲突特征（Windows ERROR_ALREADY_EXISTS：同名适配器已存在）
const _busyMarkers = <String>[
  'already exists',
  'already in use',
  'address already in use',
  'file exists',
  'device is in use',
  'in use',
];

/// 驱动/依赖加载失败特征
const _driverMarkers = <String>[
  'wintun',
  'unable to load library',
  'load library',
  'driver',
  '.dll',
  'not found',
];

/// 从内核日志中判定 TUN 是否启动失败、以及失败原因（纯函数）。
///
/// 只在 [lines] 里找到 [_fatalMarkers] 时才返回失败；分类取「最后一条致命行」
/// 及其之后的内容（内核通常把致命行与 OS 错误打在同一行或紧随其后）。
TunStartFailure detectTunStartFailure(Iterable<String> lines) {
  final all = [for (final l in lines) l.toLowerCase()];
  var lastFatal = -1;
  for (var i = 0; i < all.length; i++) {
    if (_fatalMarkers.any((m) => all[i].contains(m))) lastFatal = i;
  }
  if (lastFatal < 0) return TunStartFailure.none;

  // 致命行及其之后的若干行一起看：内核有时把 OS 错误另起一行
  final window = all.sublist(lastFatal, (lastFatal + 4).clamp(0, all.length));
  bool has(List<String> markers) =>
      window.any((l) => markers.any(l.contains));

  // 顺序即优先级：权限 → 驱动 → 冲突。
  // 「Access is denied」在驱动加载被打断时也会出现，但提权是用户真能立刻做的
  // 动作，所以优先给权限提示；纯驱动失败（无权限特征）才报被拦截。
  if (has(_privilegeMarkers)) return TunStartFailure.privilege;
  if (has(_driverMarkers)) return TunStartFailure.driver;
  if (has(_busyMarkers)) return TunStartFailure.adapterBusy;
  return TunStartFailure.unknown;
}

/// TUN 启动失败（携带分类与内核尾部日志，供上层给出可执行提示 + 落盘取证）
class TunStartException implements Exception {
  TunStartException(this.failure, this.tail);

  final TunStartFailure failure;

  /// 内核日志尾部（排查用；UI 只显示按分类生成的短文案）
  final String tail;

  @override
  String toString() => 'TUN 启动失败（${failure.name}）：$tail';
}
