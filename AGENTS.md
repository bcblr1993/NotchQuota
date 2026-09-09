# NotchQuota maintenance

- 默认中文交流；代码和符号名使用英文。
- 这是 macOS 13+ / Apple Silicon 原生 Swift Package，无第三方运行时依赖。
- 不记录或提交认证信息，不静默切换账号/组织/额度服务环境。
- 无操作 15 秒隐藏是产品约束；后台数据刷新不得触发显示或重置计时。
- 提供商解析变更添加脱敏 fixture 回归测试；保留未知与真实零额度的区别。
- 修改后运行 swift test、scripts/build-app.sh、scripts/check-release.sh。
- 修改 UI 时运行 --ui-smoke 并检查图片；不要为验证而退出用户正在工作的其他应用。
- 版本统一读取 VERSION。公开安装包必须签名、公证并通过 Gatekeeper 验证。
- 发布凭据只允许使用本机钥匙串或 GitHub Secrets，不写入仓库。
