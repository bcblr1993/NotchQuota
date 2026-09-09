# 贡献指南

1. 创建描述清楚的 Issue，再建立修复分支。
2. 保持修改范围小；接口问题先提供脱敏响应结构和复现条件。
3. 运行 `swift test`、`scripts/build-app.sh` 和 `scripts/check-release.sh`。
4. UI 改动另外验证 `--demo`、图标循环、15 秒隐藏、热点唤出，以及至少一种无刘海屏布局。
5. 更新 CHANGELOG。PR 写清问题、改变的行为、验证和未覆盖的场景。

使用 Conventional Commits，例如 `fix(claude): handle missing weekly quota`。不要提交凭据、Cookie、证书私钥、运行日志、客户数据或个人本机路径。

没有真实账户的 CI 只能运行合成数据测试。真实提供商验证由维护者本机执行，结果仅保留脱敏额度/状态，不上传认证数据。
