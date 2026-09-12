import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 注销/关机清理用的生命周期通道（AppDelegate 在 applicationShouldTerminate 时使用）
  private static var lifecycleChannel: FlutterMethodChannel?
  /// 是否已经通知过 Dart 侧（避免重复通知；让超时与回包只生效一次）
  private static var shutdownNotified = false

  /// 通知 Dart 侧做退出清理（恢复系统代理 + 停内核）。
  ///
  /// Dart 侧只做有时限的两件事（见 main.dart 的 _cleanupBeforeSystemExit）。
  /// 这里额外加 2 秒兜底：系统不会无限等，超时也必须放行退出 ——
  /// 「关机卡住」比「代理残留」更糟（残留还有下次启动巡检兜底）。
  static func notifyShutdown(completion: @escaping () -> Void) {
    guard !shutdownNotified, let channel = lifecycleChannel else {
      completion()
      return
    }
    shutdownNotified = true
    var done = false
    let finish = {
      if done { return }
      done = true
      completion()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { finish() }
    channel.invokeMethod("systemShutdown", arguments: nil) { _ in
      DispatchQueue.main.async { finish() }
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // 竖版窗口（420×780），与手机端比例一致
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let w: CGFloat = 420, h: CGFloat = 780
    let x = screenFrame.midX - w / 2
    let y = screenFrame.midY - h / 2
    let frame = NSRect(x: x, y: y, width: w, height: h)
    self.setFrame(frame, display: true)
    self.minSize = NSSize(width: 360, height: 640)

    RegisterGeneratedPlugins(registry: flutterViewController)

    MainFlutterWindow.lifecycleChannel = FlutterMethodChannel(
      name: "top.moneyfly/lifecycle",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
