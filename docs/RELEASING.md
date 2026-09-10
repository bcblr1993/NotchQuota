# 发布与维护

## 日常修复

Issue → 小范围分支 → 脱敏 fixture/测试 → PR → CI → 合入 main → 修改 VERSION 和 CHANGELOG → 发布补丁版本。

CI 每次提交运行原生测试、Apple Silicon 构建和包结构/签名验证。CI artifact 使用临时签名，名称明确标记未公证，不作为正式发布包。

## 本机签名发布

要求有效的 Developer ID Application 证书以及已存入钥匙串的 notarytool 配置。不要把证书或认证值放入源代码。

```sh
swift test
export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-notary-profile'
./scripts/build-app.sh
./scripts/check-release.sh
./scripts/package.sh
```

脚本验证签名、公证结果与票据，生成 DMG 和 SHA256SUMS。若公证超时，保留 `dist/notarization.json` 中的提交 ID，查询该提交，不重复提交：

```sh
xcrun notarytool info SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE"
xcrun notarytool log SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE"
```

确认结果为 Accepted 后完成 staple、Gatekeeper 检查、重新计算哈希，再公开上传。不能把 In Progress 当成成功。

```sh
VERSION=$(cat VERSION)
gh release create "v$VERSION" --title "NotchQuota $VERSION" \
  --notes-file docs/RELEASE_NOTES.md \
  "dist/NotchQuota-$VERSION-macos-arm64.dmg" dist/SHA256SUMS.txt dist/appcast.xml
```

## GitHub 自动签名发布

`Signed Release` 是手动触发工作流，使用 `release` environment。先配置下面这些 Secrets（只写名称，不写值）：

- `CERTIFICATE_P12_BASE64`、`CERTIFICATE_PASSWORD`、`SIGNING_IDENTITY`
- `APPLE_ID`、`APPLE_APP_PASSWORD`、`APPLE_TEAM_ID`
- `SPARKLE_PRIVATE_KEY`（更新签名，与应用内公钥对应）

缺少任何一个就会失败，不回退发布未签名安装包。证书仅导入临时钥匙串，并在最后删除。建议给 `release` environment 设置维护者审批。

本仓库不会自动从开发机导出或上传私钥；初次版本可直接用本机钥匙串发布，CI 测试与构建不需要以上秘密。

## 每版人工验收

- 从分发 DMG 安装，确认签名、Apple 公证和 Gatekeeper。
- 三个图标循环；相应登录的真实额度与原应用一致。
- 保持原应用关闭时查询（不要为测试中断用户工作中的应用）。
- 15 秒隐藏，重新进入热点唤出；后台刷新不唤出。
- 无刘海屏、刘海屏、多屏幕、休眠唤醒。
- 断网、登录失效、接口返回空/缺字段时显示明确状态。
- 实测范围写入验证记录，不宣称未测的平台或账号已经通过。

## 0.1.7 起的在线更新

Sparkle 固定版本和二进制校验记录在 Package.swift / Package.resolved。构建脚本复制 framework 并由内到外签署其辅助程序；不要只签应用最外层。CFBundleVersion 默认跟随 VERSION，后续发布必须递增。

本机首次使用 `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account NotchQuota` 建立 Ed25519 密钥（私钥仅存登录钥匙串，公钥在 Info.plist）。已有项目不得重新生成或替换公钥；本机发布沿用 NotchQuota account。CI 如启用签名发布，需另外安全配置 `SPARKLE_PRIVATE_KEY` GitHub Secret；不从本机自动导出上传。

`scripts/package.sh` 在公证完成后调用 `scripts/generate-appcast.sh`，将唯一当前版 DMG 放入临时目录，由 Sparkle 生成签名 appcast。必须将 `dist/appcast.xml` 与 DMG、SHA256SUMS 一同上传发布。订阅固定为 GitHub Releases/latest/download/appcast.xml，确保正式版设为 latest；先在 draft 上传全部文件，检查同一提交 CI、签名、公证及下载哈希后再公开。切勿手改已签名 feed；改动后重新生成。

旧 0.1.6 不包含更新器，无法自行引导更新，需手动升级一次。更新流程验证需使用一个包含更新器、build 版本较低的签名测试副本，从实际 HTTPS feed 下载更高版，检查安装后签名、版本、进程路径和开机启动状态。只改测试副本版本号不等于验证历史 0.1.6 自带在线更新。任何完整 trace、钥匙串和账户数据均不上传。
