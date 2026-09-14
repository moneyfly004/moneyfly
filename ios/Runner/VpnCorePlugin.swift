import Flutter
import Foundation
import NetworkExtension

/// App 侧 VPN 控制通道。
///
/// 与 Android 的 `top.moneyfly/vpn_core` **同名同参**，因此 Dart 侧
/// （`ProxyCoreIos`）可以复用 Android 那套结构：
///   startVpn / stopVpn / isVpnRunning / kernelVersion / fetchKernelLogs / lastStartError
///
/// 职责边界：App 只负责「把配置交给系统 VPN 子系统并起停隧道」，内核跑在
/// PacketTunnel 扩展进程里；切节点/测速/流量仍走内核的 Clash API（Dart 直连
/// 127.0.0.1:<apiPort>），与桌面/Android 完全同一套代码。
class VpnCorePlugin {

    private static let appGroupId = "group.top.moneyfly.app"
    private static let tunnelBundleId = "top.moneyfly.app.tunnel"

    /// 最近一次启动失败原因（Dart 侧连接失败时读取，给出可诊断信息）
    private static var lastError: String?

    /// 增量读内核日志的游标（字节偏移）
    private static var logCursor: UInt64 = 0

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
            default:
                result(FlutterMethodNotImplemented)
            }
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
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let url = container.appendingPathComponent("config.yaml")
            do {
                try yaml.write(to: url, atomically: true, encoding: .utf8)
                providerConf["configPath"] = url.path
            } catch {
                lastError = "写入共享配置失败：\(error.localizedDescription)"
            }
        }

        // 2) 内联兜底：App Group 不可用（未签名构建/权限缺失）或体积不大时
        //    也带一份，扩展侧优先文件、回退内联 —— 两条路都断了才报错
        if providerConf["configPath"] == nil || yaml.utf8.count < 256 * 1024 {
            providerConf["configInline"] = yaml
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
            // 复用已有配置（避免每次连接都在系统设置里堆一条 VPN 条目）
            let manager = managers?.first ?? NETunnelProviderManager()
            manager.protocolConfiguration = proto
            manager.localizedDescription = "MoneyFly"
            manager.isEnabled = true
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
                    do {
                        try manager.connection.startVPNTunnel()
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
            manager?.connection.stopVPNTunnel()
            reply(result, true)
        }
    }

    // MARK: - 状态

    private static func handleIsRunning(_ result: @escaping FlutterResult) {
        withManager { manager in
            guard let status = manager?.connection.status else {
                reply(result, false)
                return
            }
            switch status {
            case .connected, .reasserting:
                reply(result, true)
            default:
                reply(result, false)
            }
        }
    }

    private static func handleKernelVersion(_ result: @escaping FlutterResult) {
        withManager { manager in
            guard
                let session = manager?.connection as? NETunnelProviderSession
            else {
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

    // MARK: - 日志

    /// 内核日志由扩展抽到 App Group 的 kernel.log（内核缓冲在扩展进程里，
    /// App 读不到），这里沿用与 Android 相同的两种语义：
    /// - `incremental == true`：返回增量（游标推进）
    /// - 无参：返回全文（不动游标）
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

    // MARK: - 工具

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
