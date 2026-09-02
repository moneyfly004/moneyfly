import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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

    super.awakeFromNib()
  }
}
