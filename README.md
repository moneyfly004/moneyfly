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
