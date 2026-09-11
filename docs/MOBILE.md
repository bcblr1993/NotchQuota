# iOS 聚合额度应用

在 iPhone 上聚合显示 Codex / Claude / Antigravity 的多账号额度，提供主屏小组件与额度推送。

macOS 版本不受影响，本目录下的工作独立推进。

## 架构：手机自己查（B+）

凭据在 Mac 上产生，加密后经用户自己的 iCloud 传给 iPhone，**手机独立查询额度**，因此 Mac 关机时手机仍能刷新。

```
Mac（NotchQuota）                      iPhone
  读本机凭据                             ┌─ App：账号列表、扫码、设置
  用官方方式续期            密文         ├─ Widget：自取额度并渲染
  导出凭据 ────────────► CloudKit ─────► └─ 钥匙串（App Group 共享）
                         私有库                    │
                                                   ▼
                                        直接请求三家额度接口
```

### 为什么二维码里没有凭据

二维码只承载一把 32 字节传输密钥；凭据始终以密文走 CloudKit 私有库。

- 只拍到二维码 → 有密钥，但拿不到密文（在你的私有 iCloud 里）
- 只拿到 iCloud → 有密文，但没有密钥
- 两者缺一不可

重新扫码会签发新密钥并弃用旧的，这同时是换手机、Mac 重装后的恢复手段。

### 续期责任划分

| 账号 | access token 寿命 | 谁负责续期 |
| --- | --- | --- |
| Codex | 实测约 240 小时 | **只有 Mac**。续期由官方 CLI 完成（`CodexSession`），手机不实现 OAuth 刷新，因此不冒用官方客户端 |
| Antigravity | 约 1 小时 | 手机自己刷新。client_id/secret 由 Mac 在配对时下发，**不打包进 IPA** |
| Claude | 小时级 | 待定。桌面版 Cookie 含 `cf_clearance`，绑定 IP 与 UA，跨设备必然失效，只能走 OAuth 路径 |

Codex 十天的有效期意味着 Mac 每十天开机一次即可维持手机长期可用。

## 边界与已知代价

- **上架风险**：iOS 端直连三家非公开接口，触及 App Store 审核 5.2.2。当前按 TestFlight 自用推进；若改为上架，iOS 端需退回「只显示、不查询」的形态。
- **刷新频率**：WidgetKit 后台刷新由系统配额决定，每天约 40–70 次，实测约 15–30 分钟一次。前台打开立即刷新。稳定 5 分钟需要服务器轮询与静默推送，代价是凭据离开用户设备，不予采用。
- **额度重置提醒**：重置时间随额度一并同步，由 iPhone 预约本地通知，Mac 关机时照常触发。
- Claude 多账号能力取决于其 OAuth 刷新是否可用；Codex 因续期依赖单份 `auth.json`，多账号成本最高。

## NotchQuotaKit

`Packages/NotchQuotaKit` 是 macOS 与 iOS 共用的纯逻辑层，无第三方依赖——widget extension 超过约 30 MB 会被系统终止。

| 文件 | 职责 |
| --- | --- |
| `Provider.swift` | 三家应用的标识与展示名 |
| `Quota.swift` | `QuotaWindow` / `Snapshot` / `QuotaLevel`；严格区分未知、真实零值与满额 |
| `QuotaParser.swift` | 三家响应的纯解析，自 macOS 版原样移植，两端保持同一套语义 |
| `Credential.swift` | 单账号凭据与 `CredentialBundle`，含版本闸门与防回滚 |
| `Pairing.swift` | 配对信封与错误类型，60 秒有效期 |
| `PairingCrypto.swift` | AES-GCM 封装与二维码编解码 |
| `WireDate.swift` | 传输格式的毫秒归一化 |
| `Account.swift` | 多账号模型与稳定排序 |
| `AlertDetector.swift` | 额度告警状态机 |

### 两条容易踩空的实现约定

**日期按整数毫秒传输。** JSON 的 `Double` 往返并非位精确——实测五次有四次末位发生变化，而 `description` 打印完全相同。这会造成两处问题：`CredentialBundle.supersedes` 依赖 `issued` 拒绝重放的旧凭据；手机会拿新解密的 bundle 与已存的比较，相等就跳过写钥匙串和重载 widget，相等性不稳定会白白消耗每天有限的刷新配额。所有协议对象在构造时归一化到毫秒。

**告警是边沿触发且带迟滞。** 跌破 10% 告警一次，回升至 25% 以上才算恢复。滚动窗口的 `reset` 几乎每次轮询都在变，因此**不以重置时间变化作为刷新信号**。未知读数不改变状态也不推送，首次观测只记录状态，避免每次启动刷屏。

## 进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| P0 | 共享 Kit：模型、解析、配对协议、加密、告警状态机与测试 | 完成 |
| P1 | Mac 端导出凭据与二维码窗口 | 未开始 |
| P2 | CloudKit 通道与 iOS 导入 | 未开始 |
| P3 | iOS App 骨架与聚合列表 | 未开始 |
| P4 | Widget 三种尺寸 | 未开始 |
| P5 | 告警接线：CloudKit 推送与本地通知预约 | 未开始 |
| P6 | 多账号管理 | 未开始 |
| P7 | 演示模式、隐私清单、TestFlight | 未开始 |

## 本地验证

```sh
swift test --package-path Packages/NotchQuotaKit

cd Packages/NotchQuotaKit
xcodebuild -scheme NotchQuotaKit -destination 'generic/platform=iOS' build
```
