import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // #16 默认方正居中：720×520（最小 640×460，避免窄屏溢出）
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let w: CGFloat = 720, h: CGFloat = 520
    let x = screenFrame.midX - w / 2
    let y = screenFrame.midY - h / 2
    let frame = NSRect(x: x, y: y, width: w, height: h)
    self.setFrame(frame, display: true)
    self.minSize = NSSize(width: 640, height: 460)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
