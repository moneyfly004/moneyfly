import Foundation
import NetworkExtension
import os.log

#if canImport(Mihomelib)
import Mihomelib
#endif

/// iOS 上的 mihomo 宿主：Packet Tunnel Provider 扩展。
///
/// 为什么必须在这里跑内核：iOS 沙箱禁止 App 建 utun 接口，只有拥有
/// `packet-tunnel-provider` entitlement 的 NetworkExtension 才能拿到隧道。
/// 所以内核以 gomobile 静态库（Mihomelib.xcframework）形式跑在本扩展进程内，
/// TUN fd 由 `packetFlow` 提供 —— mihomo 的 sing-tun 在 `FileDescriptor != 0`
/// 时会直接复用该 fd（sing-tun/tun_darwin.go），无需 root、无需自建接口。
///
/// 与 App 的分工：
/// - App：生成 config.yaml → 写入 App Group 共享目录 → 起隧道；
/// - 扩展：读 config.yaml → 下发网络参数 → 取 fd → 启动内核 → 抽日志到共享文件；
/// - 控制面（切节点/测速/流量）：App 直连扩展内内核的 Clash API 127.0.0.1:<apiPort>，
///   与桌面/Android 完全同一套 Dart 代码。
class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "top.moneyfly.app.tunnel", category: "tunnel")
    private let appGroupId = "group.top.moneyfly.app"

    private var logPump: DispatchSourceTimer?
    private let logQueue = DispatchQueue(label: "top.moneyfly.tunnel.logpump")

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(tunnelError("缺少隧道配置（protocolConfiguration）"))
            return
        }
        let conf = proto.providerConfiguration ?? [:]

        let apiPort = (conf["apiPort"] as? NSNumber)?.intValue ?? 9090
        let localPort = (conf["localPort"] as? NSNumber)?.intValue ?? 2080
        let secret = conf["secret"] as? String ?? ""

        // 配置正文：优先 App Group 共享文件（订阅可能很大，不适合塞进
        // providerConfiguration），回退内联字符串。
        var configText: String?
        if let path = conf["configPath"] as? String, !path.isEmpty {
            configText = try? String(contentsOfFile: path, encoding: .utf8)
        }
        if configText == nil || configText!.isEmpty {
            let inline = conf["configInline"] as? String
            if let inline, !inline.isEmpty { configText = inline }
        }
        guard let yaml = configText, !yaml.isEmpty else {
            completionHandler(tunnelError("缺少内核配置（config.yaml 不可读）"))
            return
        }

        // 工作目录（可写）：扩展自己的 Application Support。
        // geo 数据随扩展 bundle 分发，首次启动复制进工作目录（mihomo 按默认
        // 文件名从 -d 目录加载 country.mmdb / geosite.dat）。
        let home = ensureHomeDir()
        seedGeoFiles(into: home)

        // 下发 tunnel 网络参数。
        // IPv4 用 fake-ip 网段 198.18.0.0/16（与生成配置里的
        // fake-ip-range 198.18.0.1/16 一致）：内核在该网段内做域名映射，
        // 地址取 198.18.0.1、DNS 指向 198.18.0.2（内核用 dns-hijack any:53 接管）。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = Self.localExcludedRoutes
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.2"])
        settings.mtu = 8500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                os_log("setTunnelNetworkSettings 失败: %{public}@", log: self.log,
                       type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            do {
                let fd = try self.tunnelFileDescriptor()
                try self.startEngine(home: home, yaml: yaml, fd: fd,
                                     apiPort: apiPort, localPort: localPort, secret: secret)
                self.startLogPump(home: home)
                os_log("内核已启动 (fd=%d, api=%d)", log: self.log, type: .info, fd, apiPort)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        os_log("stopTunnel reason=%d", log: log, type: .info, reason.rawValue)
        stopLogPump()
        #if canImport(Mihomelib)
        MihomelibStop()
        #endif
        completionHandler()
    }

    /// App 通过 `NETunnelProviderSession.sendProviderMessage` 发来的消息
    override func handleAppMessage(_ messageData: Data,
                                  completionHandler: ((Data?) -> Void)?) {
        let cmd = String(data: messageData, encoding: .utf8) ?? ""
        switch cmd {
        case "status":
            var running = false
            #if canImport(Mihomelib)
            running = MihomelibRunning()
            #endif
            completionHandler?(running ? Data("running".utf8) : Data("stopped".utf8))
        case "version":
            #if canImport(Mihomelib)
            completionHandler?(Data(MihomelibVersion().utf8))
            #else
            completionHandler?(Data("unknown".utf8))
            #endif
        default:
            completionHandler?(nil)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {}

    // MARK: - 内核

    private func startEngine(home: String, yaml: String, fd: Int32,
                             apiPort: Int, localPort: Int, secret: String) throws {
        #if canImport(Mihomelib)
        let data = Data(yaml.utf8)
        // gomobile 生成的是 C 函数 `BOOL MihomelibStart(..., NSError**)`，
        // Swift 不会自动转成 throws，需显式传 error 指针。
        var err: NSError?
        let ok = MihomelibStart(home, data, fd, &err)
        if !ok {
            throw tunnelError("内核启动失败：\(err?.localizedDescription ?? "未知错误")")
        }
        #else
        // 未链接 Mihomelib.xcframework 的构建：明确报错，绝不静默假装连上
        // （构建侧由 tool/fetch_mihomo_ios.sh + CI 保证框架存在）
        throw tunnelError("此构建未包含内核（Mihomelib.xcframework 缺失）")
        #endif
    }

    /// 取隧道 fd。
    ///
    /// `NEPacketTunnelFlow` 没有公开的 fd 访问器，业界（含 mihomo/sing-box
    /// 系 iOS 客户端）统一用 KVC 取底层 socket 的 fd。多个 keyPath 依次尝试，
    /// 全失败则给出可诊断错误（而不是崩溃或静默不连）。
    /// 注：用私有 API，因此仅适用于侧载（TrollStore / 自签），不上 App Store。
    private func tunnelFileDescriptor() throws -> Int32 {
        let paths = ["socket.fileDescriptor", "socket.fd"]
        for p in paths {
            if let n = packetFlow.value(forKeyPath: p) as? NSNumber {
                let fd = n.int32Value
                if fd > 0 { return fd }
            }
            if let fd = packetFlow.value(forKeyPath: p) as? Int32, fd > 0 {
                return fd
            }
        }
        throw tunnelError("无法获取隧道 fd（packetFlow KVC 失败）")
    }

    /// 排除本机/内网段，避免流量自绕（TUN 只接管公网流量）
    private static var localExcludedRoutes: [NEIPv4Route] {
        [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
        ]
    }

    // MARK: - 目录与 geo

    /// 扩展可写工作目录（config.yaml 与 cache.db 落这里）
    private func ensureHomeDir() -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("mihomo", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.path
    }

    /// 把随扩展 bundle 分发的 geo 数据复制进工作目录（仅缺失时，幂等）。
    /// 内核配置里 geo-auto-update=false，必须本地就位，否则 GEOSITE/GEOIP
    /// 规则会让内核对 GitHub 发起下载（国内直连被墙 → 启动卡死）。
    private func seedGeoFiles(into home: String) {
        let fm = FileManager.default
        for name in ["country.mmdb", "geosite.dat"] {
            let dest = (home as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: dest),
               let attrs = try? fm.attributesOfItem(atPath: dest),
               let size = attrs[.size] as? Int, size > 0 {
                continue
            }
            guard let src = Bundle.main.path(forResource: name, ofType: nil) else {
                os_log("geo 数据缺失: %{public}@（分流规则将降级）", log: log,
                       type: .error, name)
                continue
            }
            try? fm.removeItem(atPath: dest)
            do {
                try fm.copyItem(atPath: src, toPath: dest)
            } catch {
                os_log("geo 复制失败 %{public}@: %{public}@", log: log, type: .error,
                       name, error.localizedDescription)
            }
        }
    }

    // MARK: - 内核日志抽取

    /// mihomo 的日志缓冲在扩展进程内，App 读不到 → 由扩展抽到 App Group 共享
    /// 文件，App 侧「内核日志」页沿用 Android 的同一套读取逻辑。
    private func startLogPump(home: String) {
        stopLogPump()
        guard let file = sharedLogURL() else { return }
        let timer = DispatchSource.makeTimerSource(queue: logQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler {
            #if canImport(Mihomelib)
            let delta = MihomelibLogs()
            guard !delta.isEmpty else { return }
            Self.append(delta, to: file)
            #endif
        }
        timer.resume()
        logPump = timer
    }

    private func stopLogPump() {
        logPump?.cancel()
        logPump = nil
    }

    private func sharedLogURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        return container.appendingPathComponent("kernel.log")
    }

    private static let maxLogBytes = 512 * 1024

    private static func append(_ text: String, to url: URL) {
        let fm = FileManager.default
        guard let data = text.data(using: .utf8) else { return }
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        // 大小上限：超限则保留后半段（与桌面端日志轮转口径一致）
        if let size = try? handle.offset(), size > UInt64(maxLogBytes) {
            try? handle.close()
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let half = String(content.suffix(content.count / 2))
                try? half.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - 错误

    private func tunnelError(_ message: String) -> NSError {
        NSError(domain: "top.moneyfly.tunnel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
