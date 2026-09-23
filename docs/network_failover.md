# 线路轮换（官网/订阅域名被墙时的自救）

> 背景：2026-09-23 线上问题 —— 官网域名在部分地区被屏蔽，用户「登录不进去、
> 更新不了订阅」。服务端已把订阅域名与官网域名分开（面板「订阅域名（主/备用）」），
> 客户端这一侧由本文档描述的两套轮换机制兜底。

## 一、两套机制

| 机制 | 位置 | 作用 |
|---|---|---|
| **接口线路轮换** | `lib/core/api/server_pool.dart` + `api_client.dart` | 登录、拉订阅信息、下单等**所有 API 请求**：主域名连接失败时自动改用备用域名重试，成功即记住 |
| **订阅地址轮换** | `lib/core/services/subscribe_url_failover.dart` + `subscription_service.dart` | 拉取**订阅内容**时按「上次成功的 → 主地址 → 备用地址」逐个尝试（后端 `subscribe_urls` 下发） |

两套都遵守同一条原则：**只在"连不上"时切换，业务错误如实上报**（密码错、token 失效、
限流等换域名没有意义，重试会把业务错误掩盖成网络错误）。

## 二、域名池

`ServerPool.domains`（混淆存储，主域名在前）：

1. `https://dy.moneyfly.top/api/v1`（主/官网）
2. `https://moneyfly.dpdns.org/api/v1`
3. `https://sub.moneyfly.dpdns.org/api/v1`
4. `https://new.moneyfly.dpdns.org/api/v1`

四个域名指向**同一套后端**（token 通用、数据一致），所以换域名对用户完全透明。
服务器侧新增域名时：DNS + nginx 反代到 `127.0.0.1:8000` + 证书，然后把域名加进
`ServerPool.domains`（发版）即可。

## 三、行为细节

- **记住可用线路**：成功过的域名写入 `SharedPreferences`（`serverPoolIndex`），
  下次启动优先使用，避免每次都先撞墙；启动时 `main()` 调 `ServerPool.ensureLoaded()`。
- **重试的边界**（`ServerPool.isRetryableOnRotation`）：
  - `connectionError` / `connectionTimeout`（压根没连上）→ 任何方法都可安全重试；
  - `sendTimeout` / `receiveTimeout`（连接已建立、请求可能已送达）→ 只重试幂等方法
    （GET/HEAD/OPTIONS），**写操作不重试**，避免重复下单/签到/领券；
  - 4xx/5xx → 一律不换域名。
- **一轮请求每个域名只打一次**（`extra['_domainTried']`），池内域名都失败才上报错误。
- **订阅内容"像不像订阅"**也会判断（`looksLikeSubscription`）：机房拦截页/运营商
  提示页常返回 200 + HTML，此时继续换下一个地址，避免用户拿到解析不出节点的空订阅。

## 四、用户可自助

设置 → 网络分组 → **服务器线路**：查看当前生效域名、切换自动/指定线路、
手动填自定义域名（`ServerPool.normalizeBase` 会自动补 `https://` 与 `/api/v1`）。

自助入口的意义：官网域名全挂时，客服/群公告发出一个可用域名，用户自己填进去即可恢复。

## 五、测试

- `test/server_pool_test.dart`：域名池形状、`normalizeBase`、记住/恢复线路、
  跳过已试域名、连接失败判定、写操作重试边界、**整链验证**（假 adapter 让主域名
  连接失败 → 断言自动改打备用域名并记住）
- `test/subscribe_url_failover_test.dart`：token 提取、候选顺序、跨订阅地址不串号、
  失败后依次尝试、上次成功地址优先、拦截页/空内容视为失败、全部失败如实抛错、尝试次数上限
