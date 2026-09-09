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
  "dist/NotchQuota-$VERSION-macos-arm64.dmg" dist/SHA256SUMS.txt
```

## GitHub 自动签名发布

`Signed Release` 是手动触发工作流，使用 `release` environment。先配置下面这些 Secrets（只写名称，不写值）：

- `CERTIFICATE_P12_BASE64`、`CERTIFICATE_PASSWORD`、`SIGNING_IDENTITY`
- `APPLE_ID`、`APPLE_APP_PASSWORD`、`APPLE_TEAM_ID`

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
