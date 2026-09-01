# MoneyFly 全平台加速客户端

> Flutter 跨平台客户端（macOS / Windows / Android），对接 [https://dy.moneyfly.top](https://dy.moneyfly.top) 后端。
> 设计稿与实现细节规格见 `docs/`。

## 功能

- **登录 / 注册 / 找回密码**：邮箱验证码（60s 重发、5 分钟有效、用途隔离），JWT 自动刷新
- **一键连接**：电源按钮连接/断开；连接前自动并发测速并选择最优节点；断线自动重连（换最优节点）
- **智能 / 全局模式**：智能 = 国内直连 + 国外代理（geoip/geosite 规则）；全局 = 全部走代理；热切换不断网
- **快速切换国家**：首页国家网格，点按即切换该国最优节点
- **节点列表**：Clash YAML / v2ray base64 订阅解析，按地区分组，实时延迟徽标，搜索
- **购买套餐**：套餐卡片（后端动态）→ 优惠码验证 → 支付方式（跟随官网设置，默认支付宝）→ 二维码弹窗 → 轮询支付 → 自动开通并刷新订阅
- **我的 / 设备管理**：仪表盘（余额/到期/设备数）、设备列表（备注 ≤200 字 / 删除踢下线）、订单列表（继续支付/取消）、通知中心（已读/删除）
- **设置**：连接/模式/网络/外观/隐私/账号/关于，本地持久化
- **权限与保活**（防断连 / 防杀后台）：Android VpnService 前台服务（START_STICKY）+ 电池优化豁免 + 通知权限 + 开机自启 + 厂商后台白名单引导；macOS sandbox + network entitlements（v2 上 Network Extension）

## 技术栈

| 层 | 选型 |
|---|---|
| UI | Flutter (Material 3, 暗色 MoneyFly 主题) |
| 网络 | dio + JWT 拦截器（401 自动刷新重试） |
| 存储 | flutter_secure_storage（token）/ shared_preferences（设置） |
| 二维码 | qr_flutter |
| 订阅解析 | yaml + base64（vmess/vless/trojan/ss） |
| 测速 | dart:io Socket TCP ping（并发 12，3 次取中位数） |
| 代理内核 | sing-box（阶段 3 接入：macOS/Windows CLI + 系统代理；Android VpnService + libcore） |

## 构建

```bash
flutter pub get
flutter run -d <device>     # 开发
flutter build apk --debug   # Android
flutter build macos         # 需完整 Xcode（当前机器仅有 CommandLineTools）
flutter build windows       # 需 Windows 机器
```

## GitHub Actions 多平台多版本构建（推荐分发方式）

推送 tag 即自动构建并发布到 GitHub Releases：

```bash
git tag v1.0.0 && git push origin v1.0.0
```

也可以在 Actions 页面手动触发（可填版本号）。

### 产物清单

| 平台 | 产物 | 说明 |
|---|---|---|
| Android | `MoneyFly-android-arm64-v8a-<v>.apk` | 主流 64 位手机（2017 年后机型） |
| Android | `MoneyFly-android-armeabi-v7a-<v>.apk` | 老 32 位机型 |
| Android | `MoneyFly-android-x86_64-<v>.apk` | 模拟器 / 部分平板 |
| Android | `MoneyFly-android-<v>.aab` | 应用商店备用 |
| Windows | `MoneyFly-setup-<v>.exe` | Inno Setup 安装版（开始菜单/桌面快捷方式/卸载器） |
| Windows | `MoneyFly-windows-x64-portable-<v>.zip` | 便携版，解压即用 |
| macOS | `MoneyFly-macos-arm64-<v>.dmg` | **Apple 芯片**（M1/M2/M3/M4） |
| macOS | `MoneyFly-macos-x64-<v>.dmg` | **Intel 芯片** |
| macOS | `MoneyFly-macos-universal-<v>.dmg` | 通用版（两种芯片都能跑，体积最大） |

每个平台产物附 `SHA256SUMS.txt` 校验文件。

### 仓库 Secrets 配置（Settings → Secrets and variables → Actions）

**Android 正式签名（必配，否则回退 debug 签名，每次构建签名不同、用户无法覆盖升级）：**

| Secret | 值 |
|---|---|
| `KEYSTORE_BASE64` | `keytool -genkey -v -keystore release.keystore -alias moneyfly -keyalg RSA -keysize 2048 -validity 10000` 生成后 `base64 -i release.keystore` |
| `KEYSTORE_PASSWORD` | keystore 密码 |
| `KEY_ALIAS` | 别名（如 `moneyfly`） |
| `KEY_PASSWORD` | 密钥密码 |

> ⚠️ keystore 请妥善备份；丢失后无法对已有用户推送更新。

### 系统要求

| 平台 | 最低系统 |
|---|---|
| Android | Android 7.0+（minSdk 随 Flutter 引擎） |
| Windows | **Windows 10 (1809)+ / Windows 11** |
| macOS | macOS 10.15+（Intel 与 Apple 芯片均支持） |

> ⚠️ 关于 Windows 7：**Flutter 桌面引擎自 3.10 起已移除 Windows 7/8 支持**（官方 RFC flutter-drop-win7-2024，flutter/flutter#140830），Flutter 应用无法运行在 Win7 上。若必须覆盖 Win7 用户，需要单独用原生技术（如 Go + WinForms）开发 Win7 专用客户端，属于独立项目。本项目目标系统为 Windows 10 及以上。

### 签名与分发说明

- **Android**：配置 Secrets 后 CI 自动使用正式签名；未配置时为 debug 签名（仅供内测）。
- **macOS**：CI 产物为 ad-hoc 签名（无 Apple Developer ID）。首次打开若被 Gatekeeper 拦截，右键 → 打开即可；正式分发建议申请 Developer ID 并公证（`codesign` + `notarytool`）。
- **Windows**：未签名 exe，SmartScreen 可能提示「更多信息 → 仍要运行」；正式分发建议购买代码签名证书。

## 测试

```bash
flutter analyze   # 零问题
flutter test      # 解析器单测 + 页面组件测试
```

## 目录

```
lib/
├── main.dart                  # 入口 + 会话状态 + 连接控制器
├── theme/app_theme.dart       # MoneyFly 设计令牌
├── core/
│   ├── api/                   # ApiClient（信封解包/JWT/重试）+ 接口常量
│   ├── models/                # 全部数据模型（与后端字段对齐）
│   ├── services/              # auth/user/subscription/device/order/payment/coupon/notification/permission/settings
│   └── proxy/                 # ProxyCore 抽象 + sing-box 配置生成 + 连接状态机
└── pages/
    ├── auth/                  # 登录/注册/找回密码/修改密码
    ├── home/                  # 连接页
    ├── nodes/                 # 节点列表
    ├── package/               # 购买套餐
    ├── payment/               # 支付二维码 + 轮询
    ├── profile/               # 我的
    ├── devices/               # 设备管理
    ├── orders/                # 订单列表
    ├── notifications/         # 通知中心
    └── settings/              # 设置
android/                       # VpnService / BootReceiver / 权限通道（Kotlin）
```
