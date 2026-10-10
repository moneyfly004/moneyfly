/// 节点测速方式（用户可在设置里切换；默认内核测速）。
///
/// 对标 Shadowrocket 的「Ping / Connect」两种测速：
///
/// - [kernel]（Connect / 内核测速）：让**内核真的通过该节点发一次请求**
///   （mihomo `GET /proxies/{name}/delay`），密码/UUID/公钥/协议/回程全部
///   参与验证 —— 这才是「节点可用」。慢一点（每节点一次真实建连 + 一次
///   HTTP 往返），但不会给假阳性。
/// - [tcp]（Ping / TCP 测速）：只对 `服务器:端口` 做 TCP 握手计时。
///   快，但**只能证明端口开着**：凭据错误、协议不被内核支持、回程被墙、
///   甚至端口后面跑的根本不是代理服务（面板占位节点、被运营商劫持的
///   假 204），它一样显示「有延迟」。
///
/// 默认必须是 [kernel]：用户抱怨的正是「看起来有延迟但连不上」。
library;

enum SpeedTestMode {
  /// 内核测速（真连接，默认）
  kernel,

  /// TCP 测速（仅端口连通）
  tcp,
}

/// 默认测速方式：内核测速（真连接）。
///
/// 注意「老用户本地设置里没有这个 key」的场景：读取时**必须**回落到这里，
/// 不能抛异常、也不能退回 TCP —— 见 [parseSpeedTestMode] 与
/// `SettingsStore._defaults()`（默认值合并 + 宽容解析双重保障）。
const SpeedTestMode defaultSpeedTestMode = SpeedTestMode.kernel;

/// 持久化/展示用的稳定字符串键（写进 SettingsStore 的 JSON）。
String speedTestModeKey(SpeedTestMode mode) =>
    mode == SpeedTestMode.tcp ? 'tcp' : 'kernel';

/// 宽容解析持久化值。
///
/// **任何**无法识别的输入（null / 缺 key / 空串 / 拼错 / 非字符串）都回落到
/// [defaultSpeedTestMode]（内核测速）。这条规则是安全的：内核测速只会
/// 「更慢但更准」，回落成内核绝不会让用户看到假延迟。
SpeedTestMode parseSpeedTestMode(Object? raw) {
  final v = raw?.toString().trim().toLowerCase() ?? '';
  if (v == 'tcp' || v == 'ping') return SpeedTestMode.tcp;
  return SpeedTestMode.kernel;
}
