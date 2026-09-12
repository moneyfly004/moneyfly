import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 是否已经在走「先清理再退出」的流程（避免重复进入与死循环）
  private static var terminating = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// 退出 / 注销 / 关机：先让 Dart 侧清理系统代理与内核，再真正退出。
  ///
  /// 不接管的话，关机时系统代理会留在 127.0.0.1:<port> 指向已经死掉的端口 →
  /// 重启后整机断网，用户只能重新打开本 App 靠启动巡检恢复。
  /// （Dart 侧带 2 秒时限，见 MainFlutterWindow.notifyShutdown。）
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if AppDelegate.terminating {
      return .terminateNow
    }
    AppDelegate.terminating = true
    MainFlutterWindow.notifyShutdown {
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
