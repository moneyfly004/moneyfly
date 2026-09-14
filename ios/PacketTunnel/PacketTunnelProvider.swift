import Foundation
import NetworkExtension
import os.log

#if canImport(Mihomelib)
import Mihomelib
#endif

/// 隧道启动诊断轨迹。
///
/// 为什么需要：扩展跑在独立进程里，它的 os_log 用户看不到；而「内核日志」
/// 只有在 mihomo 成功启动之后才会产出。一旦失败（扩展没起来 / 配置没拿到 /
/// fd 取不到 / 内核启动报错），App 侧只能看到一个干巴巴的「内核启动超时」，
/// 完全无法定位。这里把启动过程的每一步都记下来，两处落地：
///   1) 内存环形缓冲 → App 通过 sendProviderMessage("diag") 实时取（扩展活着时）
///   2) App Group 的 tunnel.log → 扩展被杀后仍可事后读取
enum TunnelDiag {
    private static let queue = DispatchQueue(label: "top.moneyfly.tunnel.diag")
    private static var memory: [String] = []
    private static let maxMemory = 200
    private static let appGroupId = "group.top.moneyfly.app"
    private static let start = Date()

    static func log(_ message: String) {
        queue.async {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let line = "[\(ms)ms] \(message)"
            memory.append(line)
            if memory.count > maxMemory { memory.removeFirst(memory.count - maxMemory) }
            appendToFile(line)
        }
    }

    /// 当前轨迹（供 App 查询）。附上内核日志尾部 —— App Group 若失效，
    /// 内核日志文件写不进去，这是唯一的获取途径。
    static var trace: String {
        queue.sync {
            var out = memory.joined(separator: "\n")
            if !kernelRing.isEmpty {
                out += "\n[内核日志尾部]\n" + kernelRing.joined(separator: "\n")
            }
            return out
        }
    }

    /// 内核日志尾部（内存保留，避免 App Group 失效时完全看不到内核输出）
    private static var kernelRing: [String] = []
    private static let maxKernelRing = 60

    static func appendKernel(_ text: String) {
        queue.async {
            for line in text.split(separator: "\n") where !line.isEmpty {
                kernelRing.append(String(line))
            }
            if kernelRing.count > maxKernelRing {
                kernelRing.removeFirst(kernelRing.count - maxKernelRing)
            }
        }
    }

    /// App Group 容器是否可用（不可用意味着共享配置/kernel.log 都拿不到）
    static var appGroupPath: String? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?.path
    }

    private static func appendToFile(_ line: String) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return }
        let url = container.appendingPathComponent("tunnel.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

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
/// - 控制面（切节点/测速/流量）：App 直连扩展内内核的 Clash API 127.0.0.1:<apiPort>。
class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = OSLog(subsystem: "top.moneyfly.app.tunnel", category: "tunnel")
    private let appGroupId = "group.top.moneyfly.app"

    private var logPump: DispatchSourceTimer?
    private let logQueue = DispatchQueue(label: "top.moneyfly.tunnel.logpump")

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        TunnelDiag.log("=== startTunnel 进入 ===")
        TunnelDiag.log("App Group 容器: \(TunnelDiag.appGroupPath ?? "<不可用>")")

        // 立刻把「扩展已被系统拉起」这件事写进共享文件：即使后面任何一步失败，
        // App 侧也能凭这条区分「扩展根本没起来」和「扩展起来了但某步失败」。
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            TunnelDiag.log("✗ protocolConfiguration 类型不对")
            completionHandler(tunnelError("缺少隧道配置（protocolConfiguration）"))
            return
        }
        let conf = proto.providerConfiguration ?? [:]
        TunnelDiag.log("providerConfiguration keys: \(conf.keys.sorted())")
        let apiPort = (conf["apiPort"] as? NSNumber)?.intValue ?? 9090
        TunnelDiag.log("apiPort=\(apiPort)")

        // 配置正文：优先 App Group 共享文件（订阅可能很大，不适合塞进
        // providerConfiguration），回退内联字符串。
        var configText: String?
        var configSource = "none"
        if let path = conf["configPath"] as? String, !path.isEmpty {
            if let s = try? String(contentsOfFile: path, encoding: .utf8), !s.isEmpty {
                configText = s
                configSource = "file:\(path)"
            } else {
                TunnelDiag.log("✗ 共享配置文件不可读: \(path)")
            }
        }
        if configText == nil, let inline = conf["configInline"] as? String, !inline.isEmpty {
            configText = inline
            configSource = "inline"
        }
        guard let yaml = configText, !yaml.isEmpty else {
            TunnelDiag.log("✗ 没有可用配置（App Group 与内联都为空）")
            completionHandler(tunnelError("缺少内核配置（config.yaml 不可读）"))
            return
        }
        TunnelDiag.log("配置来源=\(configSource) 字节=\(yaml.utf8.count)")

        // 工作目录（可写）：扩展自己的 Application Support。
        let home = ensureHomeDir()
        TunnelDiag.log("homeDir=\(home)")
        seedGeoFiles(into: home)

        // 下发 tunnel 网络参数。
        // IPv4 用 fake-ip 网段 198.18.0.0/16（与生成配置里的
        // fake-ip-range 198.18.0.1/16 一致）；DNS 指向 198.18.0.2，
        // 内核用 dns-hijack any:53 接管。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = Self.localExcludedRoutes
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.2"])
        settings.mtu = 1500

        TunnelDiag.log("调用 setTunnelNetworkSettings …")
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                TunnelDiag.log("✗ setTunnelNetworkSettings 失败: \(error.localizedDescription)")
                os_log("setTunnelNetworkSettings 失败: %{public}@", log: self.log,
                       type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            TunnelDiag.log("setTunnelNetworkSettings 成功")
            // 关键设计：**隧道参数下发成功即报告就绪**，内核随后异步启动。
            //
            // 之前是在内核 Start 返回后才 completionHandler —— 一旦 Start 卡住或
            // 失败，NE 会话会一直停在 connecting：App 既拿不到「已连接」，也无法用
            // sendProviderMessage 向扩展索取诊断（会话未就绪时该调用不可用），
            // 现场就变成「20 秒后内核启动超时」且**没有任何线索**（真机实测）。
            //
            // 现在语义清晰分层：
            //  - NE 状态 connected = 隧道接口与路由就绪（这是系统关心的）
            //  - App 侧「已连接」= Clash API 可达（由 Dart 就绪探测决定，逻辑不变）
            // 内核启动失败时用 cancelTunnelWithError 主动拿下隧道，并把原因写进轨迹。
            completionHandler(nil)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let fd = try self.tunnelFileDescriptor()
                    TunnelDiag.log("取得隧道 fd=\(fd)")
                    // 先起日志抽取：mihomo 的 Logs() 用的是独立锁，
                    // Start 卡住/失败期间也能读到启动日志（含它卡在哪一步）
                    self.startLogPump()
                    try self.startEngine(home: home, yaml: yaml, fd: fd)
                    self.probeApi(port: apiPort)
                    TunnelDiag.log("✓ 内核启动完成")
                } catch {
                    TunnelDiag.log("✗ 内核启动失败: \(error.localizedDescription)")
                    // 拿掉隧道，让 App 侧立刻看到 disconnected + 本次轨迹
                    self.cancelTunnelWithError(error)
                }
            }
        }
    }

    /// 从**扩展进程内**访问内核 Clash API —— 决定性自检：
    /// - 能连上（200/401 都算连上）→ 内核与 API 都正常，问题在 App↔扩展 的路径
    /// - 连不上 → 内核没起来或 API 没监听
    /// 这段结果会进诊断轨迹，App 侧失败时一并展示。
    private func probeApi(port: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/version") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                TunnelDiag.log("API 自检(扩展内) 失败: \(err.localizedDescription)")
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            TunnelDiag.log("API 自检(扩展内) HTTP \(code) \(body.prefix(80))")
        }.resume()
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        TunnelDiag.log("=== stopTunnel reason=\(reason.rawValue) ===")
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
            TunnelDiag.log("handleAppMessage(status) → \(running ? "running" : "stopped")")
            completionHandler?(running ? Data("running".utf8) : Data("stopped".utf8))
        case "version":
            #if canImport(Mihomelib)
            completionHandler?(Data(MihomelibVersion().utf8))
            #else
            completionHandler?(Data("unknown".utf8))
            #endif
        case "diag":
            // 关键诊断通道：App 侧连接失败时拉取本扩展的启动轨迹
            TunnelDiag.log("handleAppMessage(diag) 被调用")
            completionHandler?(Data(TunnelDiag.trace.utf8))
        default:
            completionHandler?(nil)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        TunnelDiag.log("sleep")
        completionHandler()
    }

    override func wake() {}

    // MARK: - 内核

    private func startEngine(home: String, yaml: String, fd: Int32) throws {
        #if canImport(Mihomelib)
        let data = Data(yaml.utf8)
        TunnelDiag.log("调用 MihomelibStart（内核版本 \(MihomelibVersion())）…")
        let began = Date()
        // gomobile 生成的是 C 函数 `BOOL MihomelibStart(..., NSError**)`，
        // Swift 不会自动转成 throws，需显式传 error 指针。
        var err: NSError?
        let ok = MihomelibStart(home, data, fd, &err)
        let cost = Int(Date().timeIntervalSince(began) * 1000)
        if !ok {
            let why = err?.localizedDescription ?? "未知错误"
            TunnelDiag.log("✗ MihomelibStart 返回失败（\(cost)ms）: \(why)")
            throw tunnelError("内核启动失败：\(why)")
        }
        TunnelDiag.log("✓ MihomelibStart 成功（\(cost)ms）")
        #else
        TunnelDiag.log("✗ 此构建未链接 Mihomelib.xcframework")
        throw tunnelError("此构建未包含内核（Mihomelib.xcframework 缺失）")
        #endif
    }

    /// 取隧道 fd。
    ///
    /// `NEPacketTunnelFlow` 没有公开的 fd 访问器，业界（mihomo/sing-box 系 iOS
    /// 客户端）统一用 KVC 取底层 socket 的 fd。不同 iOS 版本可用的 keyPath 不完全
    /// 一致，这里逐个尝试并**记录哪一个成功**，全失败则给出可诊断错误。
    /// 注：用私有 API，因此仅适用于侧载（TrollStore / 自签），不上 App Store。
    private func tunnelFileDescriptor() throws -> Int32 {
        let paths = [
            "socket.fileDescriptor",
            "socket.fd",
            "socket.fileDescriptor.fileDescriptor",
        ]
        for p in paths {
            let value = packetFlow.value(forKeyPath: p)
            if let n = value as? NSNumber, n.int32Value > 0 {
                TunnelDiag.log("fd 来源 keyPath=\(p) 值=\(n.int32Value)")
                return n.int32Value
            }
            if let i = value as? Int32, i > 0 {
                TunnelDiag.log("fd 来源 keyPath=\(p) 值=\(i)")
                return i
            }
            TunnelDiag.log("keyPath=\(p) 未取到 fd（值=\(String(describing: value))）")
        }
        throw tunnelError("无法获取隧道 fd（packetFlow KVC 全部失败）")
    }

    /// 排除本机/内网段，避免 TUN 接管本机与局域网流量
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
                TunnelDiag.log("geo \(name) 已在位（\(size)B）")
                continue
            }
            guard let src = Bundle.main.path(forResource: name, ofType: nil) else {
                TunnelDiag.log("✗ geo 缺失于扩展 bundle: \(name)（规则将降级）")
                continue
            }
            try? fm.removeItem(atPath: dest)
            do {
                try fm.copyItem(atPath: src, toPath: dest)
                let size = ((try? fm.attributesOfItem(atPath: dest))?[.size] as? Int) ?? 0
                TunnelDiag.log("geo \(name) 已复制（\(size)B）")
            } catch {
                TunnelDiag.log("✗ geo 复制失败 \(name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 内核日志抽取

    /// mihomo 的日志缓冲在扩展进程内，App 读不到 → 由扩展抽到 App Group 共享
    /// 文件，App 侧「内核日志」页沿用 Android 的同一套读取逻辑。
    private func startLogPump() {
        stopLogPump()
        let file = sharedLogURL()
        if file == nil {
            TunnelDiag.log("App Group 不可用：内核日志只保留在内存轨迹里")
        }
        let timer = DispatchSource.makeTimerSource(queue: logQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler {
            #if canImport(Mihomelib)
            let delta = MihomelibLogs()
            guard !delta.isEmpty else { return }
            TunnelDiag.appendKernel(delta)
            if let file { Self.append(delta, to: file) }
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
