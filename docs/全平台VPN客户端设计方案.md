# 全平台 VPN 客户端设计方案（对标「小红鼠VPN」，对接 myweb 后端）

> 版本：v1.0 ｜ 日期：2026-09-01 ｜ 状态：待评审
> 目标平台：macOS / Windows / Android（后续可扩展 iOS）
> 本文档是「可修改」的设计稿：所有章节标注了【可选】【待确认】的地方，都是你可以拍板改动的地方。

---

## 0. 结论摘要（先看这一节）

1. **完全可行，而且技术路线已经由「小红鼠VPN」验证过**：小红鼠 Mac 版本身就是 **Flutter UI + sing-box 代理内核（libbox）+ macOS Network Extension** 的架构，你的电脑上正好装了 Flutter（FVM 3.41.9）、Xcode、Android SDK（API 31–36）、Go、Node，工具链齐全。
2. **你的 myweb 后端（cboard-go）已经具备本方案需要的全部接口**：登录、套餐列表、下单、支付宝支付（返回二维码）、订阅链接（Clash/V2Ray）、节点列表、设备管理、测速。**后端基本不用改**，只需要少量「按需微调」（见 §4.6）。
3. 客户端采用 **Flutter 单代码库** 覆盖 macOS / Windows / Android 三端（约 80% 代码共享），代理内核统一用 **sing-box**（支持 vmess / vless / trojan / shadowsocks / hysteria2 / tuic / wireguard，和我的面板节点类型完全兼容）。
4. 你要求的核心功能全部在方案内：
   - ✅ 登录（对接 myweb JWT）
   - ✅ 获取节点信息（订阅链接拉取）
   - ✅ 充值页 = 购买套餐（选择网站套餐 → 选支付宝/微信 → 弹出**支付宝二维码** → 扫码支付 → 自动开通 → 可连接）
   - ✅ 连接后**自动测速 + 自动选最优节点**，用户可手动切换
   - ✅ **智能模式 / 全局模式** 两种模式
5. 建议分 **6 个阶段** 实施（§7），先跑通「登录 → 订阅 → 连接」的最小闭环，再上支付和测速，最后打磨打包分发。

> ⚠️ 合规提示（务必读）：跨境代理软件在中国大陆有法律风险；上架 Apple App Store / Google Play 对 VPN 类 App 有严格审核要求（权限声明、隐私政策、Network Extension 用途说明等）。建议先走「官网下载 + 自签名分发」模式，后面再考虑商店。详见 §8.6。

---

## 1. 现状调研（我实际查看了你电脑上的东西）

### 1.1 「小红鼠VPN」Mac 版技术栈（逆向观察结果）

我查看了 `/Applications/小红鼠VPN.app`（bundle id `com.redmouse168.vpn`，版本 0.0.47）：

| 组件 | 证据 | 说明 |
|---|---|---|
| UI 框架 | `Contents/Frameworks/FlutterMacOS.framework` + 二进制内 `VPN17MainFlutterWindow` 符号 | **Flutter 桌面应用**（x86_64 + arm64 双架构） |
| 代理内核 | 二进制内含 `github.com/sagernet/sing-box/...`、`proxylibbox_CommandClient_SetClashMode`、`option.Hysteria2OutboundOptions`、`tuic.Client` 等符号 | **sing-box 内核**（SagerNet 的 libbox Go 库，cgo 编译进 Flutter 插件） |
| 系统 VPN 通道 | `Contents/PlugIns/PacketTunnel.appex` | **macOS Network Extension**（PacketTunnelProvider，系统级 VPN） |
| 额外组件 | 含 Tailscale（magicsock / DERP / wireguard 符号） | 内置 Tailscale 组件（可能用于备用通道或内网穿透） |
| 流量统计/模式切换 | `clashapi/trafficontrol`、`SetClashMode` | 用 Clash API 做流量统计和 **规则/全局模式切换** |
| 插件 | device_info / package_info / shared_preferences / path_provider / url_launcher / tray_manager（托盘）/ window_manager / share_plus / in_app_purchase_storekit（App Store 内购）/ posthog（分析）/ sentry（崩溃上报） | 标准 Flutter 桌面插件全家桶 |

**结论**：小红鼠 = Flutter UI + libbox(sing-box) + Network Extension。**我们完全可以用同一套架构做自己的产品**，且可以比它做得更轻（不需要 Tailscale、PostHog 可选）。

### 1.2 myweb 后端能力盘点（cboard-go 面板，`~/Downloads/myweb`）

我已经通读了 `docs/接口/API文档.md` 和相关 handler 源码，和你需求直接相关的接口如下：

| 你的需求 | 现成接口 | 状态 |
|---|---|---|
| 登录 | `POST /api/v1/auth/login-json`（JWT）、`/auth/refresh`、`/auth/logout` | ✅ 现成 |
| 获取节点信息 | `GET /api/v1/user/subscribe`（XBoard 兼容，需登录）→ 返回 `subscribe_url`；再 `GET /api/v1/client/subscribe?token=...&type=clash` 拿 **Clash YAML** 配置（含全部节点） | ✅ 现成 |
| 套餐列表 | `GET /api/v1/packages`（公开）— 含 name / price / duration_days / device_limit / is_recommended | ✅ 现成 |
| 下单 | `POST /api/v1/orders`，body：`{"package_id": N, "coupon_code": "..."}` | ✅ 现成 |
| 发起支付 | `POST /api/v1/payment`，body：`{"order_id": N, "payment_method_id": N}` → 返回 **`payment_qr_code`**（支付宝二维码内容） | ✅ 现成 |
| 支付方式列表 | `GET /api/v1/payment/methods`（需登录）/ `GET /api/v1/payment-methods/active`（公开） | ✅ 现成 |
| 支付状态轮询 | `GET /api/v1/orders/:orderNo/status`、`GET /api/v1/payment/status/:id` | ✅ 现成 |
| 节点列表/测速 | `GET /api/v1/nodes`、`POST /api/v1/nodes/batch-test`（服务器侧测速，可选） | ✅ 现成 |
| 用户信息 | `GET /api/v1/users/me`、`/users/dashboard-info` | ✅ 现成 |
| 设备管理 | `GET /api/v1/devices`、`DELETE /api/v1/devices/:id`（配合套餐的 device_limit） | ✅ 现成 |
| 订阅信息 | `GET /api/v1/subscriptions/user-subscription`（到期时间、剩余天数、流量） | ✅ 现成 |
| 优惠券 | `POST /api/v1/coupons/verify` | ✅ 现成 |
| 通知/公告 | `GET /api/v1/notifications` | ✅ 现成 |
| 客户端配置 | `GET /api/v1/software-config`、`/mobile-config`（公开，可放「最新版本号/下载地址/公告」） | ✅ 现成 |

**支付方式实测**：后端 `internal/services/payment/yipay.go` 实现了**易支付聚合**（`yipay_alipay` 等，直接返回 `qrcode` 字段），也支持**支付宝官方 RSA2**（`alipay` 类型，`internal/models/payment_config.go` 有 app_id / 商户私钥 / 支付宝公钥字段）。两种都最终产出「二维码内容」，客户端用 `qr_flutter` 渲染即可。

### 1.3 本机构建工具盘点（实测）

| 工具 | 版本/位置 | 用途 |
|---|---|---|
| Flutter | FVM `~/fvm/versions/3.41.9`（另有 `/Users/apple/flutter`） | 三端 UI 主框架 |
| Xcode | `/usr/bin/xcodebuild`（已装 CommandLineTools/完整 Xcode） | macOS 构建、签名、Network Extension |
| Android SDK | `/opt/homebrew/share/android-commandlinetools`：platforms android-31~36、build-tools 30~36、platform-tools | Android 构建 |
| JDK | OpenJDK 21 (Homebrew) | Android Gradle 构建 |
| Node | v24.7.0 | 前端/脚本/工具链 |
| Go | go1.24.13 | 编译 sing-box / libbox / libcore |
| Rust | cargo 1.96.0 | 可选（部分核心库需要） |
| 其它 | Python 3.14、git | 脚本辅助 |

---

## 2. 总体架构

### 2.1 客户端架构图

```
┌─────────────────────────── Flutter 客户端（三端同构） ───────────────────────────┐
│                                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │  登录/注册页 │  │  首页连接页  │  │  节点列表页  │  │ 套餐/支付页  │  ... 页面    │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘             │
│         └────────────────┴───────┬────────┴───────────────┘                      │
│                                  ▼                                               │
│  ┌───────────────────────────────────────────────────────────────────┐          │
│  │                    业务层 (Dart)                                   │          │
│  │  ApiClient(JWT/刷新/重试) · AuthStore · SubscriptionParser         │          │
│  │  NodeSelector(自动选优) · SpeedTester · Order/PaymentService      │          │
│  │  ModeController(智能/全局) · TrafficStats · DeviceRegistrar       │          │
│  └────────────────────────────────────┬──────────────────────────────┘          │
│                                       ▼                                         │
│  ┌───────────────────────────────────────────────────────────────────┐          │
│  │                    内核适配层 (跨平台抽象)                          │          │
│  │  interface ProxyCore { start(config)/stop()/switchMode()/stats() }│          │
│  └───────┬───────────────────────┬───────────────────────┬──────────┘          │
│          ▼                       ▼                       ▼                      │
│   ┌──────────────┐      ┌──────────────┐      ┌──────────────┐                  │
│   │ macOS 实现    │      │ Windows 实现  │      │ Android 实现  │                 │
│   │ libbox 插件   │      │ sing-box.exe  │      │ libcore .aar  │                │
│   │ (cgo)        │      │ 子进程 + WinTun│      │ (gomobile)    │                │
│   │ NE Packet    │      │ + 本地ClashAPI │      │ + VpnService  │                │
│   │ Tunnel       │      │               │      │               │                │
│   └──────┬───────┘      └──────┬───────┘      └──────┬───────┘                 │
│          └─────────────────────┴─────────────────────┘                          │
│                                   ▼                                              │
│                    平台系统 VPN 通道（系统设置里可见）                             │
└──────────────────────────────────────────────────────────────────────────────────┘
        │                                                          ▲
        │ HTTPS (JWT + JSON)                                        │ HTTPS
        ▼                                                          │
┌───────────────────────────────────────────────────────────────────┐
│                    myweb 后端 (cboard-go, /api/v1)                 │
│  /auth/*  /users/*  /packages  /orders  /payment  /subscribe      │
│  /nodes  /devices  /notifications  /software-config               │
│  支付宝/微信/易支付回调 /payment/notify/:type                      │
└───────────────────────────────────────────────────────────────────┘
```

### 2.2 两条核心数据流

**数据流 A：登录 → 连接**
```
输入账号密码 → POST /auth/login-json → 拿 JWT
  → GET /api/v1/user/subscribe → 拿 subscribe_url + 到期时间 + 设备数
  → GET subscribe_url (type=clash) → Clash YAML（或 v2ray base64）→ 解析出节点列表
  → 自动测速（TCP ping 并发测延迟）→ 排序 → 自动选最优节点
  → 生成 sing-box 配置 → 启动内核 → 拉起平台 VPN 通道 → 连接成功
  → 实时流量统计 + 模式切换（智能/全局）
```

**数据流 B：购买套餐 → 支付宝二维码 → 开通**
```
套餐页 GET /packages → 展示套餐卡片
  → 选套餐 POST /orders {package_id}
  → 选支付方式 GET /payment/methods
  → POST /payment {order_id, payment_method_id} → 返回 payment_qr_code
  → 客户端渲染支付宝二维码弹窗（qr_flutter）
  → 用户扫码支付（后端收到支付宝/易支付异步回调 /payment/notify/:type → 订单置为已支付）
  → 客户端轮询 GET /orders/:orderNo/status（每 2~3 秒，最长 15 分钟）
  → 状态=paid → 提示开通成功 → 重新拉订阅 → 自动连接
```

---

## 3. 技术选型（含取舍理由）

### 3.1 UI 框架：Flutter ✅（唯一推荐）
- **理由**：小红鼠同款；一套 Dart 代码出 macOS / Windows / Android；你本机 FVM 3.41.9 已就绪；生态里有 VPN 客户端现成参考（如 NekoBox、Hiddify、FlClash 都是 Flutter）。
- 备选：React Native（隧道层还是要 native）、Tauri（Rust，桌面强移动端弱）— **不推荐**。

### 3.2 代理内核：sing-box ✅
- 小红鼠用的就是它；支持全协议（vmess/vless/trojan/ss/ssr/hysteria2/tuic/wireguard），与面板节点完全兼容。
- 集成方式三选一（**按复杂度和稳定性排序**）：

| 方案 | 说明 | 平台 | 建议 |
|---|---|---|---|
| **A. sing-box CLI 子进程 + 本地 API** | 发布时把 `sing-box` 可执行文件打进安装包，App 启动它，通过 127.0.0.1 的 REST API / clash-api 控制（启停、切模式、读流量） | Windows / macOS | **v1 首选**，最简单、升级内核只换 exe |
| **B. libbox（Go 库，cgo 编译成 Flutter 插件）** | 小红鼠同款（`flutter_libbox` 插件）；把 sing-box Go 库编进 App，性能和集成度最高 | macOS / iOS | v2 打磨期再上（需要 Go + cgo 编译链，较复杂） |
| **C. libcore（SagerNet 的 go-mobile 产物）** | sing-box for Android 的核心 `.aar`，配合 VpnService | Android | **Android 首选**（可先直接用现成 libcore aar，也可自己 gomobile 编译） |

> 实际推荐组合：**Windows/macOS 用方案 A，Android 用方案 C**；后续要上 iOS 时把 macOS 切到方案 B。三端对 Dart 层的接口完全一致（ProxyCore 抽象），不影响 UI。

### 3.3 各平台系统 VPN 通道

| 平台 | 通道方案 | 关键点 |
|---|---|---|
| **macOS** | 二选一：① Network Extension（`PacketTunnelProvider`，小红鼠同款，系统级 VPN，需开发者证书 + entitlement `com.apple.developer.networking.networkextension.packet-tunnel-provider`）；② **系统代理模式**（sing-box 起本地 SOCKS/HTTP 端口 + 用 `networksetup` 设置系统代理，免签名） | **v1 建议用 ② 先跑通**（免开发者证书），v2 再上 ①（体验更好，流量计费/分流更强）。Network Extension 分发给非商店用户需要 Developer ID + 公证。 |
| **Windows** | sing-box 的 TUN 模式 + **WinTun 驱动**（WireGuard 官方驱动，`wintun.dll` 随包分发）；或以管理员权限运行 | 注意：TUN 模式需要管理员权限启动；v1 也可先用「系统代理模式」降低门槛。 |
| **Android** | **VpnService**（标准方案，免 root，系统授权弹窗） | 用方案 C 的 libcore；权限声明 `<uses-permission android:name="android.permission.BIND_VPN_SERVICE"/>`；前台服务 + 常驻通知（VPN 图标）。 |

### 3.4 关键依赖清单（pub.dev / 三方）

```
dio                  # HTTP（拦截器做 JWT 自动刷新/重试）
flutter_secure_storage  # 存 JWT / token（Keychain / Keystore）
shared_preferences   # 普通设置
provider / riverpod  # 状态管理
go_router            # 路由
qr_flutter           # 支付宝二维码渲染
yaml                 # 解析 Clash 订阅 YAML
crypto / pointycastle# 签名/哈希（设备指纹）
device_info_plus     # 上报设备信息
package_info_plus    # 版本号
path_provider        # 配置目录
tray_manager         # macOS/Windows 托盘（v2）
window_manager       # 桌面窗口控制
screen_retriever     # 多屏（可选）
flutter_local_notifications # Android 常驻通知 / 到期提醒
sentry_flutter       # 崩溃上报（可选）
posthog_flutter      # 埋点（可选）
```

---

## 4. 后端对接设计（myweb API 集成细节）

> 基础路径 `/api/v1`；除标注「公开」外都需要 `Authorization: Bearer <JWT>`。

### 4.1 登录认证
```
POST /auth/login-json
  body: {"username": "xxx", "password": "yyy"}
  resp: {access_token, refresh_token, token_type, ...}
```
- 客户端存 token 到 `flutter_secure_storage`；
- 封装 `ApiClient`：401 时用 refresh token 调 `/auth/refresh` 自动续期，重试原请求；refresh 也失败 → 强制回登录页；
- 登录页同时支持「记住密码」和「自动登录」开关（【可选】）。

### 4.2 获取节点信息（订阅模式，推荐）
```
GET /api/v1/user/subscribe        # XBoard 兼容，需登录
  resp: {
    subscribe_url: "https://你的域名/api/v1/client/subscribe?token=xxxx&type=clash",
    universal_url: "...", expire_time: "...", remaining_days: 30,
    device_limit: 3, current_devices: 1, is_expired: false, ...
  }
GET <subscribe_url>               # Clash YAML（Content-Type: text/yaml）
  resp: proxies: [...], proxy-groups: [...], rules: [...]
```
- 客户端解析 Clash YAML 得到节点列表（name / server / port / type / uuid / cipher / tls / sni / ws-path 等）；
- **备选**：`GET /nodes`（需登录）拿节点元数据（name/region/type/status/latency/speed/load），但**完整连接参数以订阅为准**（后端通过订阅下发节点真实配置），所以主链路用订阅；
- 订阅内容 `Cache-Control: no-store`，客户端每次连接前刷新（或 30 分钟缓存 + 手动刷新按钮）；
- **过期处理**：`is_expired=true` 或订阅返回「订阅已过期」错误配置 → 弹窗引导去充值页（这正是你要的「开通后才能连接」闭环）。

### 4.3 套餐购买与支付宝二维码支付（核心需求）
```
# 1) 套餐列表（公开）
GET /packages
  resp: [{id, name, description, price, duration_days, device_limit, is_recommended, ...}]

# 2) 创建订单
POST /orders
  body: {"package_id": 1, "coupon_code": "可选"}
  resp: {order_no: "20260901...", amount: 19.9, ...}

# 3) 支付方式列表
GET /payment/methods
  resp: [{id, pay_type: "alipay"|"wechat"|"yipay_alipay"|..., name, ...}]

# 4) 发起支付 → 拿二维码
POST /payment
  body: {"order_id": 123, "payment_method_id": 5}
  resp: {
    payment_qr_code: "https://qr.alipay.com/xxx" 或 "alipays://platformapi/startApp?...",  ← 二维码内容
    order_no: "...", status: "pending", ...
  }

# 5) 轮询支付结果（客户端）
GET /orders/:orderNo/status
  resp: {status: "pending"|"paid"|"cancelled"|"failed", ...}
```
- **二维码弹窗**：`payment_qr_code` 可能是 URL（如 `https://qr.alipay.com/xxx` 或易支付的 `qrcode` 图片 URL）或完整的 `alipays://` scheme 串——客户端统一用 `qr_flutter` 把字符串渲染成二维码；若返回的是图片 URL 则直接 `Image.network` 显示；
- **支付成功判断**：轮询 `/orders/:orderNo/status`（每 2~3s），或让后端在 WebSocket/长轮询推送（【可选】后端增强，见 §4.6）；状态 `paid` → 弹「开通成功」→ 刷新订阅 → 自动连接；
- 轮询超时（15 分钟）→ 提示「支付超时，请稍后在订单记录中继续支付」；
- 微信支付：`/payment/methods` 里有 wechat / yipay_wxpay 就同样渲染二维码，**一套代码两种渠道**。

### 4.4 设备管理（套餐设备数上限）
- 订阅有 `device_limit`（如 3 台）；客户端首次连接时**注册设备**：
  - 生成设备指纹：`设备ID = sha256(平台 + 主板序列号/Android ID + 安装时间盐)`，存 secure storage；
  - 拉订阅时后端已按 UA+IP 自动登记设备（XBoard 兼容逻辑）；
  - 客户端主动调 `GET /users/devices` 展示「已登录设备」，支持 `DELETE /devices/:id` 远程踢下线；
- **设备数超限**：订阅接口会返回限制提示 → 客户端弹「设备数已达上限」，引导：① 在我的页删除旧设备；② 购买设备数升级包（后端已有 `POST /orders/upgrade-devices`，【可选】接入）。

### 4.5 测速
- **客户端本地测速（主推，体验好）**：对每个节点 `server:port` 并发发起 TCP 连接计时（3 次取中位数），得到延迟；再对当前选中节点通过代理做一次 HTTP 下载测速（下载后端或 Cloudflare 测试文件 1~5MB）得到带宽。无需后端参与。
- **后端测速（可选辅助）**：`POST /nodes/batch-test`（需登录）返回服务器侧延迟/状态，可用于校正。
- 详见 §5.3 自动选优算法。

### 4.6 后端需要的少量微调（【待确认】）
1. 【建议】`/orders/:orderNo/status` 的响应里补一个 `paid_at` 时间戳（前端展示用）；
2. 【可选】新增 `GET /client/config` 公开接口：返回「最新版本号 + 各平台下载地址 + 强制更新开关 + 公告」，客户端启动时检查更新（也可直接用现成的 `/software-config` / `/mobile-config` 字段，先不新增接口）；
3. 【可选】客户端连上后，调 `POST /nodes/:id/test` 上报本机实测延迟，帮助面板展示真实数据（不强制）；
4. 【可选】支付回调后向客户端推送（WebSocket），省去轮询（v1 不推荐，轮询足够）。

---

## 5. 功能规划

### 5.1 功能清单（按优先级）

| 优先级 | 功能 | 说明 |
|---|---|---|
| P0 | 登录/自动登录/登出 | JWT + refresh |
| P0 | 拉取订阅/解析节点/手动刷新 | Clash YAML 解析 |
| P0 | 一键连接/断开 | 拉起系统 VPN 通道 |
| P0 | 智能模式 / 全局模式 | 规则分流 / 全流量代理 |
| P0 | 节点手动切换 | 列表点选，连接中热切换 |
| P0 | 套餐列表/下单/支付宝二维码支付/轮询开通 | 核心付费闭环 |
| P1 | 自动测速 + 自动选最优节点 | 连接前自动并发测速 → 评分选优（最优节点带「最优」标记 + 一键「重新测速」） |
| P1 | 快速切换国家 | 首页国家网格，点按即切换到该国最优节点（默认第一格「自动最优」） |
| P1 | 实时速率 | 上下行实时速率（套餐不限流量，**不做用量/配额统计**） |
| P1 | 我的页：账号信息/到期时间/剩余天数/设备管理 | 对接 `/users/*` `/subscriptions/*` `/devices/*` |
| P1 | 订阅过期提醒 + 一键续费跳转 | 通知 + 引导充值 |
| P1 | 托盘/常驻 + 开机自启（桌面端） | tray_manager + launch_at_login |
| P2 | 优惠券输入 | `/coupons/verify` |
| P2 | 通知中心（公告/工单） | `/notifications` |
| P2 | 测速历史/节点收藏 | 本地存储 |
| P2 | 深色模式/多语言（中/英） | 【可选】 |
| P3 | 设备数升级购买 | `/orders/upgrade-devices` |
| P3 | 检查更新/关于页 | 版本号 + 下载地址 |
| P3 | 崩溃上报 + 埋点 | Sentry / PostHog（可关） |

### 5.2 智能模式 vs 全局模式（实现原理）

- **智能模式（规则分流，默认）**：sing-box 配置里启用规则路由——
  - `geoip: cn`（国内 IP）→ `direct`（直连）
  - `geosite: cn`（国内域名，如 `geosite-cn` 规则集）→ `direct`
  - 其余流量 → `proxy`（代理）
  - 优点：国内网站/网银/视频直连不占代理流量，速度快；国外网站走代理。
- **全局模式**：所有流量（除本地/局域网外）→ `proxy`。
- **切换方式**：生成配置时同时内置两套 rules（或两套 profile），切换时通过 Clash API `SetClashMode(Rule/Global)`（小红鼠同款方式）或重启内核加载新配置；**切换不应断网**——优先用 Clash API 热切换（内核保活）。
- **界面**：首页一个醒目的「智能 / 全局」分段开关（SegmentedButton），切完立刻生效并提示。
- 【可选】智能模式里提供「规则集更新」：客户端定期从后端/上游拉取最新 geoip/geosite 规则文件（sing-box 支持远程 rule-set URL）。

### 5.3 自动测速与自动选优（算法设计）

**触发时机**：
1. 首次连接前（自动）；
2. 手动点「测速」按钮（全量重测）；
3. 【可选】连接后每 15~30 分钟后台静默重测，若当前节点劣化（延迟 > 阈值）自动切换到更优节点；
4. 【可选】断线重连时重选。

**测速方法**（本地、并发）：
```
对每个节点:
  TCP connect(server, port) × 3 次 → 取中位数 = 延迟（ms）
  失败 3 次 → 标记不可用
可选带宽测速: 仅对「候选最优」的节点，通过代理下载 1MB 测试文件计时
```

**选优评分**（可配置权重）：
```
score = w1×延迟归一化 + w2×节点负载(low) + w3×区域偏好(用户可选「优先香港/台湾/日本/美国」) + w4×节点推荐标记
默认: 延迟权重最高（w1=0.6, w2=0.2, w3=0.1, w4=0.1）
选 score 最高且在线节点
```
- 结果展示：节点列表每项显示实时延迟徽标（绿 <100ms / 黄 100~300 / 红 >300 / 灰不可用），按延迟升序排列，当前节点置顶高亮并带「最优」标记；首页「自动测速卡」显示当前最优节点 + 重新测速按钮。
- **快速切换国家**：测速结果按国家聚合出「该国最低延迟」，首页国家网格每格实时显示该值，点按即切换到该国最优节点（同时更新当前最优）。
- **用户随时可手动点选任意节点**，自动选优只作为默认行为，不锁定用户选择；【可选】「记住我的选择，不自动切换」开关。

### 5.4 连接状态机

```
未登录 → 已登录(未订阅/已过期) → 已就绪(有订阅有节点)
已就绪 ──连接──> 测速中 ──> 连接中 ──> 已连接(流量统计/模式切换)
已连接 ──断开/断线──> 已就绪；断线自动重连(最多N次)
```

---

## 6. 界面规划（UI/UX）

> 设计基调：**MoneyFly 品牌视觉**——黑色 `#0B0E14` 底 + 品牌蓝紫 `#455FE9`（渐变 `#6C7BFF → #7A5CFF`）+ 成功绿 `#2EE6A8`，暗色科技风为主（设计稿见 `design/`，含手机/桌面/品牌规范 14 张）。

### 6.1 登录页
- Logo + App 名称；账号/密码输入框；登录按钮（加载态）；「自动登录」「记住密码」开关；
- 底部：「注册账号」「忘记密码」入口（App 内嵌流程，见 6.1.1 / 6.1.2）；
- 登录成功 → 拉订阅 → 有订阅进首页，无订阅/已过期 → 引导到套餐页。

### 6.1.1 注册页（含邮箱验证码）
- 字段：**邮箱**（接收验证码）→ **验证码**（「发送验证码」按钮 + 60s 倒计时重发，输入框 6 位数字样式）→ **用户名** → **密码**（≥8 位）→ **确认密码** → **邀请码（选填）**；
- 底部勾选「我已阅读并同意《用户协议》《隐私政策》」；
- 接口：`POST /auth/verification/send {type:"email", email}` 发码（5 分钟有效）→ `POST /auth/register {username, email, password, verification_code, invite_code?}`；
- 错误处理：验证码错误/已过期、邮箱已被注册、注册功能被后台关闭（返回「注册功能已禁用」时提示联系客服）。

### 6.1.2 找回密码（两步 + 邮箱验证码）
- 步骤条：「① 验证身份 → ② 设置新密码」；
- 第一步：输入注册邮箱 → 「发送验证码」→ 输入 6 位验证码；
- 第二步：新密码 + 确认新密码 → 「重置密码」→ 成功跳回登录页；
- 接口：`POST /auth/forgot-password {email}` → `POST /auth/reset-password {email, verification_code, new_password}`；
- 与注册共用验证码防刷（60s 重发限制、5 分钟过期、用途隔离——注册码不能用于重置）。

### 6.1.3 设置页（完整清单，设计稿 09/13）
- **连接设置**：启动时自动连接（开关）· 自动测速并选最优（开关）· 断线自动重连（开关，最多 3 次）· 后台测速间隔（默认 30 分钟）· DNS 服务器（默认 223.5.5.5，可选 1.1.1.1/8.8.8.8/自定义）· 协议过滤（默认全部协议）；
- **模式**：默认模式（智能 / 全局）；
- **网络**（桌面端）：TUN 虚拟网卡（自动 / 强制）· 绕过局域网流量（开关）；
- **外观**：主题（跟随系统 / 深色 / 浅色）· 语言（简体中文 / English）；
- **隐私**：允许通知（套餐到期/连接提醒）· 崩溃日志上报（Sentry，默认关）· 匿名使用统计（PostHog，默认关）；
- **账号**：修改密码（需邮箱验证码）· 退出登录（红色警示）；
- **关于**：检查更新（当前 v1.0.0）· 用户协议 · 隐私政策；
- **桌面端额外**：开机自启、托盘常驻（并入「连接设置」/ 外观分组）；
- 顶部「恢复默认」按钮；修改即时生效并本地持久化。

### 6.2 首页（连接页）★核心页
```
┌─────────────────────────────┐
│  [托盘图标]  🖥 我的VPN   [⚙]│  ← 顶栏
├─────────────────────────────┤
│                             │
│         ┌─────────┐         │
│         │  电源大按钮 │        │  ← 中央连接按钮（呼吸动画，连接中旋转）
│         │  连接/断开 │        │
│         └─────────┘         │
│    ● 当前节点: 香港-01 (35ms) │  ← 点按切换节点
│    [智能模式 | 全局模式]      │  ← SegmentedButton 模式切换
│  ┌────────────────────────┐ │
│  │ ⚡ 自动测速 · 自动选优 已开启 │ │  ← 自动测速状态卡
│  │  🇭🇰 香港-01 35ms [最优]  │ │
│  │  [⟳ 重新测速]             │ │
│  │  连接前自动测速 · 断线自动重选  │ │
│  └────────────────────────┘ │
│  ┌ 快速切换国家 ───────────┐ │
│  │ ✨自动最优  🇭🇰香港  🇯🇵日本 │ │  ← 点按即切换该国最优节点
│  │ 🇸🇬新加坡  🇹🇼台湾  🇺🇸美国 │ │
│  │ 🇰🇷韩国    🇬🇧英国  🇩🇪德国 │ │
│  └────────────────────────┘ │
│   ↑ 1.2 MB/s   ↓ 8.5 MB/s   │  ← 实时速率（套餐不限流量，无用量统计）
├─────────────────────────────┤
│  底部导航: [首页] [节点] [充值] [我的] │
└─────────────────────────────┘
```
- 未连接时：按钮灰色「点击连接」，下方提示「连接时将自动测速并选择最优节点」；
- 已连接时：按钮红色「断开」，节点名 + 延迟 + 速率实时刷新；
- **自动测速卡**：展示自动选优开关状态、当前最优节点（带「最优」标记）、「重新测速」按钮；测速后延迟实时更新；
- **快速切换国家**：每格显示国旗 + 该国**当前最低延迟**，点按即切换到该国最优节点；第一格「自动最优」= 全局自动选优；
- 套餐均为**不限流量**，因此不展示用量/配额，只保留实时速率作为连接质量指示；
- 模式切换处放小字说明：「智能=国内直连国外代理；全局=全部走代理」。

### 6.3 节点页
- 顶部：搜索框 + 「测速」按钮 + 「自动选择最优」按钮；
- 节点分组：按地区分组（🇭🇰 香港 / 🇹🇼 台湾 / 🇯🇵 日本 / 🇺🇸 美国 / 🇸🇬 新加坡…），每组可折叠；
- 每行：节点名 + 类型标签（Vmess/ Trojan/Hysteria2…）+ 延迟徽标 + 负载 + 「当前」标记；
- 交互：点选切换（连接中热切换）；长按 → 收藏/置顶/查看详情（【可选】）；
- 排序：按延迟 / 按地区 / 按推荐。

### 6.4 套餐/充值页 ★核心页
```
┌─────────────────────────────┐
│  购买套餐                    │
│  [月付 ¥19.9] [季付 ¥49.9] [年付 ¥179 推荐] │  ← 套餐卡片横向排列（推荐套餐带角标）
│  ── 套餐详情 ──              │
│  时长: 90天 · 设备: 3台 · 流量: 不限量     │
│  优惠码: [____] [验证]       │
│  ── 支付方式 ──              │
│  (●) 支付宝   ( ) 微信支付   ( ) USDT  │  ← 来自 /payment/methods
├─────────────────────────────┤
│  [ 立即支付 ¥49.9 ]          │
└─────────────────────────────┘
```
- 套餐数据来自 `GET /packages`（后端配了哪些套餐就显示哪些，客户端不写死）；
- 点「立即支付」→ 创建订单 → 发起支付 → 弹出**支付二维码弹窗**（见 6.5）；
- 支付成功后 Toast + 自动跳回首页并连接。

### 6.5 支付二维码弹窗（模态）
```
┌──────────────────────┐
│  请使用支付宝扫码支付   │
│  ┌──────────────┐    │
│  │   [二维码]    │    │  ← qr_flutter 渲染 payment_qr_code
│  └──────────────┘    │
│  订单号: 20260901xxxx │
│  金额: ¥49.9          │
│  ⏳ 等待支付...(已 30s) │  ← 轮询中，转圈动画
│  [我已支付] [取消]      │
└──────────────────────┘
```
- 支付成功后弹窗自动关闭；
- 支持「复制订单号」「打开支付宝 App 直接跳转」（`alipays://` scheme，用 url_launcher，【可选】）。

### 6.6 我的页
- 头像/昵称/邮箱；余额（后端有 balance 字段，可展示）；
- 订阅卡片：套餐名、到期时间、剩余天数、设备数（当前/上限）、流量用量；
- 「设备管理」入口（列表 + 删除/踢下线）；
- 「我的订单」入口（订单列表 + 状态）；
- 「优惠券」「邀请码」「通知」入口（【可选】）；
- 「设置」「关于」「退出登录」。

### 6.8 桌面端附加（macOS/Windows）
- **托盘菜单**：连接/断开、显示主窗、当前节点、模式切换、退出——托盘图标随连接状态变色（红=断开、绿=连接）；
- **迷你窗/悬浮窗**：连接状态 + 速率小窗（【可选】）；
- **系统菜单栏图标**（macOS）：点击展开下拉。

### 6.9 设计规范（建议）
- 色板：主色红 `#E53935`、成功绿 `#34C759`、背景暗 `#121212`/亮 `#F5F5F7`；
- 圆角：卡片 16px、按钮 12px；间距 4/8/12/16/24 网格；
- 字体：默认系统字体（SF Pro / 微软雅黑 / Roboto），数字用等宽字体（速率、延迟）；
- 图标：Lucide/Remix 风格线性图标；
- 动效：连接按钮呼吸光圈、测速进度、切换节点淡入淡出（配合 ui-animation 打磨）。

---

## 7. 具体实施步骤（分阶段，可裁剪）

> 每阶段都有明确的产出和验收标准；建议按顺序执行，P0 阶段完成后你就能看到「能用的 App」。

### 阶段 0：项目初始化（0.5 天）
- `flutter create` 三平台工程（`org.example.vpn` 改成你的包名）；
- 建好目录结构（见 §9），配好分析器/lint；
- 验证三端空壳能跑：macOS（`flutter run -d macos`）、Android（模拟器/真机）、Windows（需 Windows 机器或后续）。

### 阶段 1：后端对接基础层（1~2 天）
- 封装 `ApiClient`（dio + JWT 拦截器 + 自动刷新 + 错误统一处理）；
- 实现登录/自动登录/登出、`/users/me`、`/subscriptions/user-subscription`；
- 实现 `SubscriptionService`：拉订阅 → 解析 Clash YAML → 节点模型（含本地缓存）；
- **验收**：App 里能看到你的真实节点列表。

### 阶段 2：UI 骨架（2~3 天）
- 登录页、首页（连接按钮/当前节点/模式开关）、节点页、我的页（占位）；
- 底部导航 + 路由 + 状态管理接线；
- **验收**：能登录、能看节点、界面可用。

### 阶段 3：连接能力（最核心，3~5 天）
- 实现 `ProxyCore` 抽象 + 平台实现：
  - macOS：方案 A（sing-box CLI + 系统代理）先跑通；
  - Windows：方案 A（sing-box.exe + WinTun 或系统代理）；
  - Android：VpnService + libcore（先用现成 aar）；
- 生成 sing-box 配置（节点转 sing-box 格式 + 智能/全局两套规则）；
- 连接/断开/热切换节点/切模式（Clash API）；
- 流量统计（读内核 API）；
- **验收**：三端能连上节点、能切模式、能切节点、能看到流量。

### 阶段 4：支付闭环（2~3 天）
- 套餐页（`/packages`）+ 下单 + 支付方式选择；
- 二维码弹窗（qr_flutter）+ 轮询支付状态 + 开通成功引导；
- 订阅过期/无订阅时的充值引导；
- **验收**：真机扫码支付宝支付 → 订单变已支付 → 订阅开通 → 自动连接。

### 阶段 5：测速与自动选优（2~3 天）
- 并发 TCP ping 测速引擎 + 延迟徽标 + 排序；
- 自动选优算法 + 连接前自动测速 + 断线重连重选；
- 手动刷新测速、手动切换不受影响；
- **验收**：连接前自动选中最优节点，列表延迟实时准确。

### 阶段 6：打磨与分发（3~5 天）
- 我的页完善（设备管理/订单/到期提醒）、设置页、托盘、开机自启；
- 图标/启动图/品牌色；
- 打包：macOS `.dmg`（自签名或公证）、Windows 安装包（Inno Setup / NSIS / MSIX）、Android APK/AAB；
- 检查更新 + 官网下载页（对接 `/software-config`）；
- 崩溃上报（Sentry）开启；
- **验收**：三端安装包可分发、新用户从下载到付费到连接全流程走通。

> 总工期预估（一个人全栈）：**3~4 周**（不含 iOS、不含商店上架）。

---

## 8. 技术难点与风险

| # | 难点 | 说明与对策 |
|---|---|---|
| 1 | sing-box 三端集成 | 先用「CLI 子进程」统一（Windows/macOS），Android 用 libcore aar；Dart 层接口抽象后，换内核实现不动 UI。 |
| 2 | macOS Network Extension 签名 | NE 需要开发者证书 + entitlement +（分发需）公证。**v1 用系统代理模式规避**；v2 上 NE 时准备好 Apple Developer 账号（$99/年）。 |
| 3 | Windows TUN 权限 | WinTun 需要管理员权限；用 manifest `requireAdministrator` 或「以管理员身份重启」提示；也可先系统代理模式。 |
| 4 | Android VpnService | 标准流程：`prepare()` → `startVpnService()` → 前台服务 + 常驻通知；注意电池优化白名单（可选引导用户加入）。 |
| 5 | 支付回调时序 | 客户端轮询 15 分钟兜底；后端 `/payment/notify/:type` 已是标准实现，回调成功即开通；轮询与回调双通道，避免丢单。 |
| 6 | 订阅过期/设备超限 | 订阅接口已返回错误配置与提示（`订阅已过期`/`订阅已失效`/设备限制），客户端解析后引导充值/删设备。 |
| 7 | 热切换不断网 | 用 Clash API 切 mode/切 outbound（内核保活），避免重启内核；sing-box 支持 `PATCH /configs` 动态改。 |
| 8 | 节点配置安全 | 订阅 URL 含 token，客户端存 secure storage；HTTPS 全链路；日志不打印完整订阅 token。 |
| 9 | 流量统计准确性 | 读内核 API 的 up/down 累计值；断线重连后重置会话统计，保留累计统计。 |
| 10 | 多语言/多分辨率 | Flutter 自适应布局；桌面端窗口最小尺寸限制；Android 折叠屏适配（P2）。 |
| 11 | **合规与商店政策** | 见下节 8.6。 |

### 8.6 合规与分发策略（重要）
- **中国大陆法律**：经营跨境代理服务需持证（工信部 VPN 牌照极难获得）；个人/小团队「机场」模式普遍存在但法律风险自担。建议：境内合规化（仅对境外业务/出海场景）、注册主体 + 免责声明、实名制（后端已支持邀请码/实名可选）。
- **Apple App Store**：VPN 类上架需 `Network Extension` 用途说明、隐私政策、审核时提供测试账号；`in_app_purchase` 要求内购走 IAP（小红鼠就接了 storekit，苹果抽成 15~30%）。**建议 v1 官网分发，暂不上商店**。
- **Google Play**：需声明 VPN 权限用途 + 隐私政策；对「VPN 翻墙」类政策更严格（国内机场基本无法上架），建议官网/第三方市场分发 APK。
- **Windows**：无商店也可分发；可选 Microsoft Store（需开发者账号）。
- **备案/域名**：你的 myweb 域名需 ICP 备案（若国内服务器）；支付需企业资质（支付宝当面付/易支付需要营业执照或使用第三方聚合）。

---

## 9. 项目目录结构建议

```
vpn-client/  (新建 Flutter 工程)
├── lib/
│   ├── main.dart
│   ├── app.dart                    # 主题/路由/初始化
│   ├── core/
│   │   ├── api/                    # ApiClient, 各端 API service
│   │   │   ├── auth_api.dart
│   │   │   ├── package_api.dart   # 套餐/订单/支付
│   │   │   ├── subscribe_api.dart # 订阅/节点
│   │   │   └── user_api.dart      # 用户/设备
│   │   ├── models/                # user/package/order/node/subscription
│   │   ├── storage/               # secure_storage + prefs 封装
│   │   └── utils/                 # 设备指纹/时间/格式化
│   ├── services/                  # 业务逻辑
│   │   ├── subscription_service.dart  # 拉取+解析 Clash YAML
│   │   ├── node_selector.dart        # 测速+自动选优
│   │   ├── speed_tester.dart         # TCP ping 引擎
│   │   ├── payment_service.dart      # 下单/轮询
│   │   └── traffic_service.dart      # 流量统计
│   ├── core_proxy/                # 内核抽象层
│   │   ├── proxy_core.dart        # 抽象接口
│   │   ├── proxy_core_cli.dart    # 方案A: sing-box CLI 实现
│   │   ├── config_builder.dart    # 节点→sing-box 配置生成(智能/全局)
│   │   └── platform/
│   │       ├── macos_impl.dart
│   │       ├── windows_impl.dart
│   │       └── android_impl.dart  # VpnService + libcore
│   ├── pages/
│   │   ├── login_page.dart
│   │   ├── home_page.dart         # 连接页
│   │   ├── nodes_page.dart
│   │   ├── package_page.dart
│   │   ├── payment_dialog.dart    # 二维码弹窗
│   │   ├── profile_page.dart
│   │   └── settings_page.dart
│   ├── widgets/                   # 电源按钮/延迟徽标/套餐卡片等
│   └── theme/
├── macos/  windows/  android/     # 平台壳 + entitlements + manifest
├── assets/                        # 图标/启动图/规则集(geoip/geosite 本地兜底)
├── sing-box/                      # 各平台内核二进制/wintun.dll（打包用）
└── docs/                          # 本设计文档 + API 备忘
```

---

## 10. 待你确认的事项（决定下一步）

> ✅ 已确认（2026-09-01）：品牌 **MoneyFly**；logo 沿用 myweb 品牌（黑色圆角方块 + 品牌蓝紫 `#455FE9` 「M」字标）；后端域名 **https://dy.moneyfly.top**；支付方式**跟随官网后台设置实时同步**（默认支付宝）。设计稿见 `design/` 目录（10 张图 + 可编辑 HTML 源文件）。

1. **Windows 开发机**：当前这台是 Mac，Windows 端只能交叉开发（写代码 + 远程/虚拟机验证），需要准备一台 Windows 机器或 Parallels 虚拟机（你已装 Parallels Desktop）做最终构建与测试。
2. **iOS**：是否纳入二期？（技术上同架构可扩展，需 Apple 开发者账号 + Mac 构建 + 审核）。
3. **自动选优的策略**：默认「延迟优先」可以吗？是否要「区域优先」（如默认选香港）选项？
4. **是否需要注册功能**：App 内注册，还是仅登录 + 引导去网站注册？
5. **上线形态**：官网直发（dmg/exe/apk）为主，还是也要走应用商店？
6. **设计稿配色/布局确认**：暗色科技风 + 品牌蓝紫是否符合预期？需要亮色版或其它风格随时说。

---

## 附录 A：客户端调用后端的关键接口速查（给开发用）

```text
基础地址  https://<你的域名>/api/v1
认证      POST /auth/login-json            body: {username, password}
          POST /auth/refresh               body: {refresh_token}
          POST /auth/logout
用户      GET  /users/me
          GET  /users/dashboard-info
订阅      GET  /subscriptions/user-subscription
          GET  /api/v1/user/subscribe      (XBoard 兼容，返回 subscribe_url/到期/设备数)
订阅拉取  GET  /client/subscribe?token=<订阅token>&type=clash    → Clash YAML
套餐      GET  /packages                    (公开)
订单      POST /orders                      body: {package_id, coupon_code?}
          GET  /orders/:orderNo/status
支付      GET  /payment/methods
          POST /payment                     body: {order_id, payment_method_id}
          GET  /payment/status/:id
          resp: {payment_qr_code, ...}
节点      GET  /nodes                       (可选，元数据)
          POST /nodes/batch-test            (服务器侧测速，可选)
设备      GET  /devices
          DELETE /devices/:id
优惠券    POST /coupons/verify
配置      GET  /software-config  /mobile-config  (公开，放版本号/下载地址/公告)
```

## 附录 B：sing-box 配置生成示例（智能/全局）

```yaml
# 智能模式（规则分流）核心片段
route:
  rules:
    - geoip: [cn]
      outbound: direct
    - geosite: [cn]
      outbound: direct
    - network: [udp]
      outbound: proxy          # UDP 默认走代理（游戏/语音）
  final: proxy                 # 其余走代理

# 全局模式核心片段
route:
  final: proxy                 # 全部走代理
  rules:
    - ip_cidr: [127.0.0.0/8, 10.0.0.0/8, 192.168.0.0/16]  # 仅放行本地
      outbound: direct

outbounds:
  - type: vless
    tag: 香港-01
    server: 1.2.3.4
    server_port: 443
    uuid: xxxx-xxxx-xxxx
    tls: { enabled: true, server_name: "hk01.example.com" }
    flow: xtls-rprx-vision          # 按节点实际协议生成
  - type: direct
    tag: direct
```

---

*本文档由调研你电脑上的小红鼠VPN + myweb 后端后编写，所有接口与字段均以你后端实际代码为准（`~/Downloads/myweb/internal/api/...`）。有任何一处想改（架构、配色、功能范围、优先级），直接告诉我，我出修订版。*
