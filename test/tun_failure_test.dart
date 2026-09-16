// TUN 启动失败判定：只认真正的启动失败，不把正常告警当致命。
//
// 背景（旧实现 `_tunFailedInLog`）：判定是「行里同时含 tun 和 error/failed」，
// 而 mihomo 有一批正常日志同样命中 —— 最典型的是
// `[TUN] Auto detect interface for <名> failed, return '<invalid>' …`
// （多虚拟网卡 / Hyper-V / 某些 VPN 环境下探不到出口接口，属正常告警）。
// 后果：一条本来正常的连接被判死、提示「请以管理员身份运行」，用户按提示提权
// 后依旧失败，真因被掩盖。
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/proxy/tun_failure.dart';

void main() {
  group('detectTunStartFailure：正常告警不得判为失败', () {
    test('auto-detect-interface 探测失败（最常见误判源）', () {
      expect(
        detectTunStartFailure([
          'time="..." level=warning msg="[TUN] Auto detect interface for Ethernet 2 failed, return \'<invalid>\' to avoid lookback"',
        ]),
        TunStartFailure.none,
      );
    });

    test('默认网卡监控/名称类日志', () {
      expect(
        detectTunStartFailure([
          'msg="[TUN] default interface changed by monitor, => Ethernet"',
          'msg="[TUN] default interface lost by monitor"',
          'msg="[TUN] use tun name Meta"',
          'msg="[TUN] Tun adapter listening at: Meta"',
        ]),
        TunStartFailure.none,
      );
    });

    test('数据面转发错误（连接期偶发，不代表 TUN 没起来）', () {
      expect(
        detectTunStartFailure([
          'error writing to TUN device',
          'Failed to read packet from TUN device',
          'error reading from TUN device',
        ]),
        TunStartFailure.none,
      );
    });

    test('空日志 / 正常启动日志', () {
      expect(detectTunStartFailure(const []), TunStartFailure.none);
      expect(
        detectTunStartFailure([
          'level=info msg="[TUN] Tun adapter listening at: MoneyFly"',
        ]),
        TunStartFailure.none,
      );
    });
  });

  group('detectTunStartFailure：分类正确', () {
    test('权限不足 → privilege', () {
      expect(
        detectTunStartFailure([
          'level=error msg="Start TUN listening error: configure tun interface: Access is denied."',
        ]),
        TunStartFailure.privilege,
      );
      expect(
        detectTunStartFailure([
          'Start TUN listening error: operation not permitted',
        ]),
        TunStartFailure.privilege,
      );
    });

    test('同名网卡已存在 → adapterBusy（残留适配器，提权也没用）', () {
      expect(
        detectTunStartFailure([
          'level=error msg="Start TUN listening error: Cannot create a file when that file already exists."',
        ]),
        TunStartFailure.adapterBusy,
      );
    });

    test('驱动无法加载 → driver（多被安全软件拦截）', () {
      expect(
        detectTunStartFailure([
          'level=error msg="Start TUN listening error: unable to load library: wintun"',
        ]),
        TunStartFailure.driver,
      );
    });

    test('致命行与 OS 错误分行时也能归类（内核常见打两行）', () {
      expect(
        detectTunStartFailure([
          'level=error msg="Start TUN listening error"',
          'Access is denied.',
        ]),
        TunStartFailure.privilege,
      );
    });

    test('致命串无更多线索 → unknown（不编原因）', () {
      expect(
        detectTunStartFailure(['level=error msg="Start TUN listening error"']),
        TunStartFailure.unknown,
      );
      expect(
        detectTunStartFailure(['Start Tun interface timeout']),
        TunStartFailure.unknown,
      );
    });

    test('多条致命行取最后一条（本轮为准，不被上一轮残留带偏）', () {
      expect(
        detectTunStartFailure([
          'Start TUN listening error: Access is denied.',
          'Start TUN listening error: wintun unable to load library',
        ]),
        TunStartFailure.driver,
      );
    });
  });
}
