import Flutter
import Foundation
import NetworkExtension

/// App 侧 VPN 控制通道。
///
/// 与 Android 的 `top.moneyfly/vpn_core` **同名同参**，因此 Dart 侧
/// （`ProxyCoreEmbedded`）可以复用 Android 那套结构：
///   startVpn / stopVpn / isVpnRunning / kernelVersion / fetchKernelLogs / lastStartError
/// 另外为 iOS 增加诊断方法（Android 无对应实现，Dart 侧按需调用）：
///   vpnStatus / fetchTunnelLog / fetchTunnelDiag
///
/// 职责边界：App 只负责「把配置交给系统 VPN 子系统并起停隧道」，内核跑在
/// PacketTunnel 扩展进程里；切节点/测速/流量仍走内核的 Clash API（Dart 直连
/// 127.0.0.1:<apiPort>）。
class VpnCorePlugin {

    private static let appGroupId = "group.top.moneyfly.app"
    private static let tunnelBundleId = "top.moneyfly.app.tunnel"

    /// 最近一次启动失败原因（Dart 侧连接失败时读取，给出可诊断信息）
    private static var lastError: String?

    /// App 侧诊断轨迹：记录每次连接尝试的关键节点与 NE 会话状态变化。
    /// 与扩展侧轨迹互补 —— 即使扩展根本没起来（或 App Group 失效读不到扩展文件），
    /// 这里也能看出「配置是否保存成功 / 会话经历了哪些状态 / 最终停在哪」。
    private static var diagNotes: [String] = []
    private static let diagStart = Date()
    private static var statusObserver: NSObjectProtocol?

    private static func note(_ message: String) {
        let ms = Int(Date().timeIntervalSince(diagStart) * 1000)
        diagNotes.append("[\(ms)ms] \(message)")
        if diagNotes.count > 300 { diagNotes.removeFirst(diagNotes.count - 300) }
        NSLog("[moneyfly] %@", message)
    }

    private static func statusName(_ s: NEVPNStatus) -> String {
        switch s {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    /// 增量读内核日志的游标（字节偏移）
    private static var logCursor: UInt64 = 0

    /// 隧道进入 reasserting 的时刻。该中间态若持续过久，说明隧道实际已不可用，
    /// 但 NEVPNStatus 仍报「活着」—— 看门狗会因此永远不判死（真机「假连接」根因）。
    private static var reassertingSince: Date?

    /// NE 状态变化的事件通道（原生 → Dart）。系统状态是最终事实，必须回传，
    /// 否则扩展被 iOS 终止后 App 会一直停在「已连接」。
    static var statusSink: FlutterEventSink?

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "top.moneyfly/vpn_core", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "startVpn":
                handleStart(call, result)
            case "stopVpn":
                handleStop(result)
            case "isVpnRunning":
                handleIsRunning(result)
            case "kernelVersion":
                handleKernelVersion(result)
            case "fetchKernelLogs":
                handleFetchLogs(call, result)
            case "lastStartError":
                result(lastError ?? "")
            case "vpnStatus":
                handleVpnStatus(result)
            case "fetchTunnelLog":
                handleFetchTunnelLog(result)
            case "fetchTunnelDiag":
                handleFetchTunnelDiag(result)
            case "fetchVpnDiag":
                reply(result, diagNotes.joined(separator: "\n"))
            case "fetchKernelStderr":
                // 内核（Go）的 stdout/stderr：崩溃转储、fatal error、panic 全在这里。
                // 扩展被系统杀掉时这是唯一的现场，必须让 App 能读到。
                reply(result, Self.kernelStderrTail(lines: 120))
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // 状态事件通道：NE 状态一变就推给 Dart（含首次订阅时的当前状态回放）。
        let statusChannel = FlutterEventChannel(
            name: "top.moneyfly/vpn_status", binaryMessenger: messenger)
        statusChannel.setStreamHandler(StatusStreamHandler())
    }

    /// FlutterEventChannel 的 StreamHandler：订阅时回放当前状态，之后随
    /// NEVPNStatusDidChange 持续推送。
    final class StatusStreamHandler: NSObject, FlutterStreamHandler {
        func onListen(withArguments arguments: Any?,
                      eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            VpnCorePlugin.statusSink = events
            VpnCorePlugin.emitCurrentStatus()
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            VpnCorePlugin.statusSink = nil
            return nil
        }
    }

    // MARK: - start / stop

    private static func handleStart(_ call: FlutterMethodCall,
                                    _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        guard let yaml = args["configYaml"] as? String, !yaml.isEmpty else {
            reply(result, FlutterError(code: "no_config", message: "缺少内核配置", details: nil))
            return
        }
        let apiPort = (args["apiPort"] as? NSNumber)?.intValue ?? 9090
        let localPort = (args["localPort"] as? NSNumber)?.intValue ?? 2080
        let secret = args["clashSecret"] as? String ?? ""

        var providerConf: [String: Any] = [
            "apiPort": apiPort,
            "localPort": localPort,
            "secret": secret,
        ]

        // 1) 优先写 App Group 共享文件：订阅配置可能几百 KB，塞进
        //    providerConfiguration（系统 VPN 偏好）不合适
        var wroteFile = false
        let groupPath = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?.path
        note("startVpn: 配置 \(yaml.utf8.count)B, App Group=\(groupPath ?? "<不可用>")")
        if let groupPath {
            let url = URL(fileURLWithPath: groupPath).appendingPathComponent("config.yaml")
            do {
                try yaml.write(to: url, atomically: true, encoding: .utf8)
                providerConf["configPath"] = url.path
                wroteFile = true
                note("已写入共享配置 \(url.path)")
            } catch {
                lastError = "写入共享配置失败：\(error.localizedDescription)"
                note("✗ 写共享配置失败: \(error.localizedDescription)")
            }
        } else {
            note("App Group 不可用（entitlement 未生效？）→ 配置只能内联传递")
        }
        // 2) 内联兜底：App Group 不可用时这是唯一通路。上限 1MB ——
        //    providerConfiguration 会存进系统 VPN 偏好，过大不合适；
        //    正常订阅配置（几百 KB 以内）都能带上。
        if !wroteFile || yaml.utf8.count < 1024 * 1024 {
            providerConf["configInline"] = yaml
            note("已附带内联配置 \(yaml.utf8.count)B（不依赖 App Group）")
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleId
        proto.serverAddress = "MoneyFly"
        proto.providerConfiguration = providerConf

        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                fail("读取 VPN 配置失败：\(error.localizedDescription)", result)
                return
            }
            // 只复用「本扩展」的配置：managers 里可能有用户其它 VPN 配置，
            // 直接取 first 会覆盖别人的 profile，也会起错扩展。
            let existing = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == tunnelBundleId
            }
            let manager = existing ?? NETunnelProviderManager()
            manager.protocolConfiguration = proto
            manager.localizedDescription = "MoneyFly"
            manager.isEnabled = true
            // 开启按需连接：扩展被 iOS 终止（内存压力/崩溃）后由系统自动重建隧道，
            // 避免「断了就一直断」。用户手动断开时会在 handleStop 里先关掉它，
            // 否则 NEOnDemandRuleConnect 会立刻把隧道重新拉起来。
            manager.isOnDemandEnabled = true
            manager.onDemandRules = [NEOnDemandRuleConnect()]
            manager.saveToPreferences { error in
                if let error {
                    fail("保存 VPN 配置失败：\(error.localizedDescription)", result)
                    return
                }
                // saveToPreferences 之后必须重新 load，connection 才可用
                manager.loadFromPreferences { error in
                    if let error {
                        fail("加载 VPN 配置失败：\(error.localizedDescription)", result)
                        return
                    }
                    note("配置已保存（复用已有=\(existing != nil)），开始观察会话状态")
                    observeStatus(manager)
                    do {
                        try manager.connection.startVPNTunnel()
                        note("startVPNTunnel 已发起，当前状态=\(statusName(manager.connection.status))")
                        lastError = nil
                        reply(result, true)
                    } catch {
                        fail("启动隧道失败：\(error.localizedDescription)", result)
                    }
                }
            }
        }
    }

    private static func handleStop(_ result: @escaping FlutterResult) {
        withManager { manager in
            guard let manager else {
                reply(result, true)
                return
            }
            // 必须先关按需再停隧道：否则 NEOnDemandRuleConnect 会在断开瞬间
            // 立刻把隧道重新拉起来，用户「断开」等于无效。
            manager.isOnDemandEnabled = false
            manager.saveToPreferences { _ in
                manager.loadFromPreferences { _ in
                    manager.connection.stopVPNTunnel()
                    reply(result, true)
                }
            }
        }
    }

    // MARK: - 状态

    private static func handleIsRunning(_ result: @escaping FlutterResult) {
        withManager { manager in
            guard let status = manager?.connection.status else {
                // 查询不到 manager 不代表团建已断：loadAllFromPreferences 在前后台
                // 切换/系统繁忙的瞬间可能短暂返回空。保守返回 true（宁可不断，
                // 也不误杀）—— 旧实现返回 false，是看门狗反复误判「内核死亡」、
                // 连接每 1~2 分钟被重连一次的直接原因。
                reply(result, true)
                return
            }
            switch status {
            case .connected:
                reply(result, true)
            case .reasserting:
                // 卡在 reasserting 超过 10s → 隧道实际已不可用，按断开处理。
                // 旧实现无条件返回 true，看门狗因此永远不会判死（假连接根因）。
                let stuck = reassertingSince.map {
                    Date().timeIntervalSince($0) > 10
                } ?? false
                reply(result, !stuck)
            default:
                reply(result, false)
            }
        }
    }

    /// 隧道详细状态（诊断用）：`none/<无配置>`、`invalid/…`、`disconnected/…` 等
    private static func handleVpnStatus(_ result: @escaping FlutterResult) {
        let groupOk = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) != nil
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            let manager = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == tunnelBundleId
            }
            guard let manager else {
                reply(result, "no-manager/AppGroup=\(groupOk)")
                return
            }
            reply(result,
                  "\(statusName(manager.connection.status))/enabled=\(manager.isEnabled)"
                  + "/AppGroup=\(groupOk)")
        }
    }

    private static func handleKernelVersion(_ result: @escaping FlutterResult) {
        withManager { manager in
            guard let session = manager?.connection as? NETunnelProviderSession else {
                reply(result, "unknown")
                return
            }
            do {
                try session.sendProviderMessage(Data("version".utf8)) { data in
                    let v = data.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
                    reply(result, v)
                }
            } catch {
                reply(result, "unknown")
            }
        }
    }

    // MARK: - 日志与诊断

    /// 内核日志由扩展抽到 App Group 的 kernel.log（内核缓冲在扩展进程里，
    /// App 读不到），这里沿用与 Android 相同的两种语义：
    /// - `incremental == true`：返回增量（游标推进）
    /// - 无参：返回全文（不动游标）
    /// App Group 里 go-stderr.log 的尾部（内核崩溃/致命错误现场）。
    private static func kernelStderrTail(lines: Int) -> String {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return "" }
        let url = container.appendingPathComponent("go-stderr.log")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if all.count <= lines { return text }
        return all.suffix(lines).joined(separator: "\n")
    }

    private static func handleFetchLogs(_ call: FlutterMethodCall,
                                       _ result: @escaping FlutterResult) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            reply(result, "")
            return
        }
        let url = container.appendingPathComponent("kernel.log")
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            reply(result, "")
            return
        }
        defer { try? handle.close() }

        let args = call.arguments as? [String: Any] ?? [:]
        let incremental = args["incremental"] as? Bool == true

        if !incremental {
            let data = (try? handle.readToEnd()) ?? Data()
            reply(result, String(data: data, encoding: .utf8) ?? "")
            return
        }
        if args["reset"] as? Bool == true { logCursor = 0 }
        let size = (try? handle.seekToEnd()) ?? 0
        if logCursor > size { logCursor = 0 }  // 文件被轮转
        do {
            try handle.seek(toOffset: logCursor)
        } catch {
            reply(result, ["log": "", "hasMore": false])
            return
        }
        let data = (try? handle.readToEnd()) ?? Data()
        logCursor = (try? handle.offset()) ?? logCursor
        reply(result, [
            "log": String(data: data, encoding: .utf8) ?? "",
            "hasMore": false,
        ])
    }

    /// 扩展写入 App Group 的启动轨迹（tunnel.log）——扩展被系统杀掉后仍可读
    private static func handleFetchTunnelLog(_ result: @escaping FlutterResult) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            reply(result, "App Group 不可用，扩展轨迹文件无法读取")
            return
        }
        let url = container.appendingPathComponent("tunnel.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            reply(result, "（暂无 tunnel.log：扩展可能从未被系统拉起）")
            return
        }
        reply(result, text)
    }

    /// 向**正在运行的扩展**索取内存里的启动轨迹（sendProviderMessage）。
    /// 失败本身就是有价值的信息：说明扩展没在运行。
    private static func handleFetchTunnelDiag(_ result: @escaping FlutterResult) {
        withManager { manager in
            guard let session = manager?.connection as? NETunnelProviderSession else {
                reply(result, "扩展未运行（无 VPN 配置）")
                return
            }
            do {
                try session.sendProviderMessage(Data("diag".utf8)) { data in
                    let text = data.flatMap { String(data: $0, encoding: .utf8) }
                    reply(result, text ?? "（扩展返回空）")
                }
            } catch {
                reply(result, "扩展未运行（sendProviderMessage 失败：\(error.localizedDescription)）")
            }
        }
    }

    // MARK: - 工具

    /// 观察 NE 会话状态变化（真机排查关键：连接尝试往往停在某个中间态）。
    private static func observeStatus(_ manager: NETunnelProviderManager) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        let conn = manager.connection
        note("会话初始状态=\(statusName(conn.status))")
        updateReasserting(conn.status)
        emitStatus(statusName(conn.status))
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: conn, queue: .main
        ) { _ in
            let name = statusName(conn.status)
            note("NE 状态 → \(name)")
            updateReasserting(conn.status)
            emitStatus(name)
        }
    }

    /// 记录/清除 reasserting 起始时间（用于判断是否卡死在该中间态）。
    private static func updateReasserting(_ status: NEVPNStatus) {
        if status == .reasserting {
            if reassertingSince == nil { reassertingSince = Date() }
        } else {
            reassertingSince = nil
        }
    }

    /// 把当前 NE 状态回放给刚订阅的 Dart 侧。
    static func emitCurrentStatus() {
        withManager { manager in
            guard let manager else { return }
            updateReasserting(manager.connection.status)
            emitStatus(statusName(manager.connection.status))
        }
    }

    /// 推送状态到 Dart（主线程）。
    static func emitStatus(_ name: String) {
        DispatchQueue.main.async {
            statusSink?(name)
        }
    }

    private static func withManager(_ body: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            let manager = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == tunnelBundleId
            }
            body(manager)
        }
    }

    /// FlutterResult 必须在主线程回调
    private static func reply(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    private static func fail(_ message: String, _ result: @escaping FlutterResult) {
        lastError = message
        reply(result, FlutterError(code: "start_failed", message: message, details: nil))
    }
}
