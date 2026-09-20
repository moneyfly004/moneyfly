import Foundation
import NetworkExtension
import ObjectiveC
import UIKit
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

/// **用户态桥**：把 `packetFlow`（文档 API）与内核要读写的 fd 对接起来。
///
/// 为什么需要它（真机实测结论，v2.2.13 / iOS 16.6.1 / iPhone14,3）：
///   `NEPacketTunnelFlow` 的 `_socket` ivar 类型是 `NSFileHandle` 且**恒为 nil**，
///   也就是说这个 iOS 版本上 flow 走的是新的 `NEVirtualInterface` 后端，
///   **根本不暴露 utun 的 fd** —— 社区常见的
///   `packetFlow.value(forKeyPath: "socket.fileDescriptor")` 在这里无解
///   （我们把 keyPath 扩到 13 条、轮询 49 次、还 kick 了 readPackets，全是 nil）。
///
/// 桥的做法：`socketpair(AF_UNIX, SOCK_DGRAM)` 造一对 fd，把其中一端交给内核，
/// 另一端由本类在两个方向上搬运数据包：
///   App → 隧道：`packetFlow.readPackets` → 加 4 字节地址族头 → `send()` 给内核
///   内核 → App：`recv()` 到 4 字节头 + IP 包 → 去头 → `packetFlow.writePackets`
/// 4 字节头是 sing-tun 在 Darwin 上的既定格式（`tun_darwin.go`：
/// `packetHeader4 = {0,0,0,AF_INET}`、`PacketOffset = 4`），已核对源码。
///
/// 好处：只用**文档 API + BSD socket**，不再依赖任何会随 iOS 版本变化的私有结构。
/// 代价：多一次用户态拷贝（实测吞吐仍远高于隧道本身带宽需求）。
final class PacketBridge {
    private let flow: NEPacketTunnelFlow
    /// 交给内核读写的那一端
    let kernelFd: Int32
    /// 桥自己这一端
    private let bridgeFd: Int32
    private var running = true
    private let queue = DispatchQueue(label: "top.moneyfly.tunnel.bridge")
    private var outPackets = 0   // App → 内核
    private var inPackets = 0    // 内核 → App
    private var dropped = 0

    init?(flow: NEPacketTunnelFlow) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            TunnelDiag.log("✗ socketpair 创建失败 errno=\(errno)")
            return nil
        }
        self.flow = flow
        self.bridgeFd = fds[0]
        self.kernelFd = fds[1]
        // 桥这侧用 poll 等数据，非阻塞写；内核侧由 sing-tun 自己 SetNonblock(false)
        _ = fcntl(bridgeFd, F_SETFL, O_NONBLOCK)
        TunnelDiag.log("✓ 用户态桥就绪：内核 fd=\(kernelFd) 桥 fd=\(bridgeFd)")
    }

    func start() {
        queue.async { [weak self] in self?.bridgeLoop() }
        pumpFromFlow()
    }

    func stop() {
        running = false
        close(bridgeFd)
        close(kernelFd)
    }

    var stats: String {
        "桥统计：App→内核 \(outPackets) 包 / 内核→App \(inPackets) 包 / 丢弃 \(dropped)"
    }

    /// 内核 → App：从桥这一端读「4 字节头 + IP 包」，去头后写回隧道
    private func bridgeLoop() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while running {
            var pfd = pollfd(fd: bridgeFd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 200)
            if ready <= 0 { continue }
            let n = recv(bridgeFd, &buf, buf.count, 0)
            if n > PacketBridge.headerLength {
                let af = Int32(buf[3])
                let packet = Data(buf[PacketBridge.headerLength..<Int(n)])
                inPackets += 1
                flow.writePackets([packet], withProtocols: [NSNumber(value: af)])
                if inPackets % 50 == 0 { TunnelDiag.log(stats) }
            } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                TunnelDiag.log("✗ 桥 recv 失败 errno=\(errno)")
                break
            }
        }
    }

    /// App → 内核：读隧道里的包，加 4 字节地址族头后交给内核
    private func pumpFromFlow() {
        flow.readPackets { [weak self] packets, protocols in
            guard let self, self.running else { return }
            for (i, packet) in packets.enumerated() {
                let af: Int32 = i < protocols.count ? protocols[i].int32Value : AF_INET
                var framed = Data([0, 0, 0, UInt8(truncatingIfNeeded: af)])
                framed.append(packet)
                let sent = framed.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return send(self.bridgeFd, base, framed.count, 0)
                }
                if sent < 0 { self.dropped += 1 } else { self.outPackets += 1 }
                if self.outPackets % 50 == 0 { TunnelDiag.log(self.stats) }
            }
            if self.running { self.pumpFromFlow() }
        }
    }

    /// sing-tun 在 Darwin 上每个包前面都带 4 字节地址族头
    static let headerLength = 4
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

    /// 用户态桥（直连 fd 拿不到时启用；stopTunnel 时要关掉，否则 fd 泄漏）
    private var bridge: PacketBridge?
    private let appGroupId = "group.top.moneyfly.app"

    private var logPump: DispatchSourceTimer?
    private let logQueue = DispatchQueue(label: "top.moneyfly.tunnel.logpump")

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        TunnelDiag.log("=== startTunnel 进入 ===")
        TunnelDiag.log("系统=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
            + " 机型=\(Self.hardwareModel())")
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
                    let acquired = try self.acquireKernelFd()
                    let fd = acquired.fd
                    self.bridge = acquired.bridge
                    TunnelDiag.log("取得隧道 fd=\(fd)"
                        + (acquired.bridge == nil ? "（直连）" : "（用户态桥）"))
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
        // 用户态桥必须显式关掉：否则 socketpair 的两个 fd 会留在扩展进程里
        if let bridge {
            TunnelDiag.log(bridge.stats)
            bridge.stop()
            self.bridge = nil
        }
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

    private struct FdHit {
        let fd: Int32
        let source: String
    }

    /// `packetFlow` 上可能挂着底层 socket fd 的 keyPath（按历史/版本从常用到冷门）
    private static let flowFdPaths = [
        "socket.fileDescriptor",
        "socket.fd",
        "socket._fileDescriptor",
        "socket.fileDescriptor.fileDescriptor",
        "_socket.fileDescriptor",
        "_socket.fd",
        "socket.socket.fileDescriptor",
        "tunnelFlow.socket.fileDescriptor",
        "socket.fileDescriptor.fileDescriptor.fileDescriptor",
    ]

    /// 少数版本把 fd 挂在 provider 自己身上
    private static let providerFdPaths = [
        "tunnelFileDescriptor",
        "_tunnelFileDescriptor",
        "socket.fileDescriptor",
        "packetFlow.socket.fileDescriptor",
    ]

    /// 取隧道 fd：**轮询 + 多路径 + 运行时兜底 + 失败时打印真实结构**。
    ///
    /// 为什么不能像旧版那样「取一次、三条 KVC、失败就报错」：
    /// 真机日志（TrollStore / iOS，v2.2.10）显示
    ///     [320ms] setTunnelNetworkSettings 成功
    ///     [321ms] socket.fileDescriptor / socket.fd / socket.fileDescriptor.fileDescriptor 全 nil
    ///     [322ms] ✗ 内核启动失败: 无法获取隧道 fd
    /// 三条路径都返回 nil 而**没有抛 NSUnknownKeyException**，说明 `_socket` 这个
    /// ivar 是存在的、只是**值为 nil** —— `NEPacketTunnelFlow` 内部那个 socket 由
    /// 系统在隧道真正 up 之后才**懒创建**，而我们比它早了 1ms 去取。
    ///
    /// 现在：轮询重试（默认 6s）→ 仍取不到就 kick 一次 `readPackets`（**文档 API**，
    /// 会迫使内部 socket 建立）→ 再取不到就把 packetFlow / provider 的**真实 ivar
    /// 结构**写进诊断轨迹，下一版可按图索骥，而不是继续猜。
    ///
    /// 注：取 fd 本身用私有 KVC，因此仅适用于侧载（TrollStore / 自签），不上 App Store。
    /// 取得给内核用的 fd：**先试直连，再退回用户态桥**。
    ///
    /// - 直连：老 iOS / 某些机型上 `packetFlow` 会暴露 utun fd（省掉一次拷贝）；
    /// - 桥：iOS 16.4+ 的 `NEVirtualInterface` 后端不再暴露 fd（本机实测），
    ///   用 socketpair 自己搬运数据包。
    private func acquireKernelFd() throws -> (fd: Int32, bridge: PacketBridge?) {
        // 直连只做一次短探测（0.5s）：真机实测 iOS 16.6.1 上 `_socket` 恒为 nil，
        // 等久了只是白拖慢连接；但其它 iOS 版本上它可能一次就成（省掉一次用户态拷贝）
        if let fd = try? tunnelFileDescriptor(timeout: 0.5) {
            return (fd, nil)
        }
        TunnelDiag.log("直连 fd 不可得 → 改用 socketpair 用户态桥（只用文档 API）")
        guard let bridge = PacketBridge(flow: packetFlow) else {
            throw tunnelError("无法建立隧道 fd，且用户态桥创建失败")
        }
        bridge.start()
        return (bridge.kernelFd, bridge)
    }

    private func tunnelFileDescriptor(timeout: TimeInterval = 6) throws -> Int32 {
        let started = Date()
        var attempt = 0
        var kicked = false
        while Date().timeIntervalSince(started) < timeout {
            attempt += 1
            if let hit = probeTunnelFd() {
                TunnelDiag.log("取得隧道 fd=\(hit.fd)（来源=\(hit.source)，第 \(attempt) 次尝试，"
                    + "耗时 \(Int(Date().timeIntervalSince(started) * 1000))ms）")
                return hit.fd
            }
            if !kicked && attempt >= 3 {
                kicked = true
                TunnelDiag.log("fd 仍为空 → kick packetFlow.readPackets 强制建立内部 socket")
                kickPacketFlow()
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        dumpTunnelStructure()
        throw tunnelError("无法获取隧道 fd（已轮询 \(attempt) 次 / \(Int(timeout))s；"
            + "packetFlow 与 provider 的真实结构已写入诊断轨迹）")
    }

    /// 单次探测：先试已知 keyPath，再用 Objective-C runtime 兜底找 fd 形状的 ivar
    private func probeTunnelFd() -> FdHit? {
        for p in Self.flowFdPaths {
            if let fd = Self.intValue(of: packetFlow, keyPath: p), fd > 2 {
                return FdHit(fd: fd, source: "packetFlow.\(p)")
            }
        }
        for p in Self.providerFdPaths {
            if let fd = Self.intValue(of: self, keyPath: p), fd > 2 {
                return FdHit(fd: fd, source: "provider.\(p)")
            }
        }
        if let fd = Self.runtimeFindFd(in: packetFlow, depth: 0) {
            return FdHit(fd: fd, source: "runtime(packetFlow)")
        }
        if let fd = Self.runtimeFindFd(in: self, depth: 0) {
            return FdHit(fd: fd, source: "runtime(provider)")
        }
        return nil
    }

    /// 用**文档 API** `readPackets` 踢一脚：内部 socket 只有在第一次读包时才会
    /// 真正建立（这就是我们 1ms 取不到 fd 的原因）。
    /// 代价：这一下可能吃掉极少量「刚进隧道」的包（TCP 会重传、DNS 会重试），
    /// 属于一次性代价，且只在轮询 3 次仍失败时才做。
    private func kickPacketFlow() {
        packetFlow.readPackets { _, _ in
            TunnelDiag.log("kick 完成（readPackets 返回，socket 应已建立）")
        }
    }

    // MARK: - 安全取属性（绝不因为 key 不存在而崩扩展）

    /// 该 ivar 是否适合走 KVC（对象 / 数字 / 布尔）。
    ///
    /// struct（类型编码 `{...}`）、数组 `[...]`、联合与位域 `(...)` 走 KVC 会抛
    /// `NSUnknownKeyException` —— Swift 捕获不到，会**直接把扩展干崩**。
    /// 结构 dump 会遍历所有 ivar，所以必须先按类型编码过滤。
    private static func isKvcSafeIvar(_ ivar: Ivar) -> Bool {
        guard let encPtr = ivar_getTypeEncoding(ivar),
              let first = String(cString: encPtr).first else { return false }
        return "@cislqCISLQfdB".contains(first)
    }

    /// 是否存在该 ivar（含沿父类链查找 `_name` / `name` 两种写法）
    private static func hasIvar(_ obj: AnyObject, _ name: String) -> Bool {
        var cls: AnyClass? = object_getClass(obj)
        while let c = cls {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(c, &count) {
                for i in 0..<Int(count) {
                    if let n = ivar_getName(ivars[i]), String(cString: n) == name {
                        free(ivars)
                        return true
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(c)
        }
        return false
    }

    /// 读一段属性路径：逐段检查「有 getter 或有同名 ivar」后再取值。
    /// `value(forKeyPath:)` 对完全不存在的 key 会抛 NSUnknownKeyException（Swift
    /// 捕获不到，直接把扩展干崩），所以这里必须自己逐段检查。
    private static func safeGet(_ obj: AnyObject, _ segment: String) -> Any? {
        if obj.responds(to: NSSelectorFromString(segment)) {
            return obj.value(forKey: segment)
        }
        let candidates = ["_\(segment)", segment]
        if candidates.contains(where: { hasIvar(obj, $0) }) {
            return obj.value(forKey: segment)
        }
        return nil
    }

    /// 取整型属性（支持 a.b.c 路径）
    private static func intValue(of obj: AnyObject, keyPath: String) -> Int32? {
        var current: AnyObject? = obj
        for seg in keyPath.split(separator: ".") {
            guard let cur = current else { return nil }
            guard let next = safeGet(cur, String(seg)) else { return nil }
            current = next as AnyObject
        }
        guard let v = current else { return nil }
        if let n = v as? NSNumber { return n.int32Value }
        if let i = v as? Int { return Int32(i) }
        if let i = v as? Int32 { return i }
        if let i = v as? Int64 { return Int32(i) }
        if let i = v as? UInt32 { return Int32(i) }
        return nil
    }

    /// runtime 兜底：递归找「名字像 fd、值也像 fd」的 ivar（跨 iOS 版本自适应）。
    /// 名字优先匹配 fd/fileDescriptor/socket，避免误取无关整型。
    private static func runtimeFindFd(in obj: AnyObject, depth: Int) -> Int32? {
        guard depth <= 3 else { return nil }
        var cls: AnyClass? = object_getClass(obj)
        var visited = 0
        while let c = cls, visited < 6 {
            visited += 1
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(c, &count) {
                for i in 0..<Int(count) {
                    guard let namePtr = ivar_getName(ivars[i]) else { continue }
                    let name = String(cString: namePtr)
                    let lower = name.lowercased()
                    let looksLikeFd = lower.contains("fd") || lower.contains("filedescriptor")
                        || lower.contains("socket") || lower.contains("tunnel")
                    guard looksLikeFd, isKvcSafeIvar(ivars[i]) else { continue }
                    if let v = safeGet(obj, name.hasPrefix("_") ? String(name.dropFirst()) : name) {
                        if let n = v as? NSNumber, n.int32Value > 2 { free(ivars); return n.int32Value }
                        if let n = v as? Int, n > 2 { free(ivars); return Int32(n) }
                        let child = v as AnyObject
                        if String(describing: type(of: child)).hasPrefix("NS") == false
                            || String(describing: type(of: child)).hasPrefix("NE") {
                            if let fd = runtimeFindFd(in: child, depth: depth + 1) {
                                free(ivars)
                                return fd
                            }
                        }
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(c)
        }
        return nil
    }

    /// 全部策略失败时，把真实结构写进诊断轨迹（下一版据此精确取 fd）
    private func dumpTunnelStructure() {
        TunnelDiag.log("—— packetFlow 结构（取不到 fd 时供定位）——")
        TunnelDiag.log(Self.describe(packetFlow, depth: 0))
        TunnelDiag.log("—— provider 结构 ——")
        TunnelDiag.log(Self.describe(self, depth: 0))
    }

    private static func describe(_ obj: AnyObject, depth: Int) -> String {
        guard depth <= 2 else { return "…" }
        let indent = String(repeating: "  ", count: depth)
        var lines = ["\(indent)\(type(of: obj)) {"]
        var cls: AnyClass? = object_getClass(obj)
        var visited = 0
        while let c = cls, visited < 4 {
            visited += 1
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(c, &count) {
                for i in 0..<Int(count) {
                    guard let namePtr = ivar_getName(ivars[i]) else { continue }
                    let name = String(cString: namePtr)
                    let type = ivar_getTypeEncoding(ivars[i]).map { String(cString: $0) } ?? "?"
                    let plain = name.hasPrefix("_") ? String(name.dropFirst()) : name
                    var valueDesc = "<非 KVC 类型，跳过取值>"
                    if isKvcSafeIvar(ivars[i]), let v = safeGet(obj, plain) {
                        valueDesc = "<取不到>"
                        if let n = v as? NSNumber {
                            valueDesc = "\(n)"
                        } else {
                            valueDesc = String(describing: v)
                            if valueDesc.count > 80 { valueDesc = String(valueDesc.prefix(80)) + "…" }
                            lines.append("\(indent)  \(name): \(type) = \(valueDesc)")
                            lines.append(describe(v as AnyObject, depth: depth + 1))
                            continue
                        }
                    } else if isKvcSafeIvar(ivars[i]) {
                        valueDesc = "<取不到>"
                    }
                    lines.append("\(indent)  \(name): \(type) = \(valueDesc)")
                }
                free(ivars)
            }
            cls = class_getSuperclass(c)
        }
        lines.append("\(indent)}")
        return lines.joined(separator: "\n")
    }

    /// 机型标识（诊断用：不同机型/系统版本的私有结构可能不同）
    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { acc, el in
            if let v = el.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(v)))) }
        }
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
