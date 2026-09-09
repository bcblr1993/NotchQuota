# 本机性能观察与优化

## 产品约束

保持紧凑图标与百分比常驻，每 60 秒按 Codex → Claude → Antigravity 轮换已安装应用；15 秒收起详情并保留当前应用。交互和休眠时暂停轮换，自动轮换不额外查询，仅切换时进行 0.38 秒淡入淡出。不要增加额度线、呼吸灯、循环动画、遥测或额外后台服务。额度仍每 180 秒查询，单提供商请求间隔至少 30 秒；屏幕/系统休眠暂停发起新请求，唤醒尝试刷新，已在途的请求可能正常完成。

## 低开销采样

在仓库执行 `scripts/monitor-performance.sh 240 10`。首次使用 Xcode 的 Swift 编译器编译采样工具，后续复用 `.build/performance/probe`。默认将独立 JSONL 文件保存到 `~/Library/Logs/NotchQuota/Performance`。不写入应用，不在应用内加定时器，不采集账号、凭据、请求地址或进程内存内容。

工具用 macOS `proc_pid_rusage` 读取目标应用的内核计数，每 10 秒一次，运行 4 分钟后退出。只选择 `/Applications/NotchQuota.app/Contents/MacOS/NotchQuota`；应用未运行或进程结束则记录事件并退出，不自行启动。PID 的启动时间用于阻止重用 PID 被误算。

指标：CPU 用户态+内核态时间增量 / 实际采样间隔（100% 为一个核心）；resident size (RSS)；physical footprint（用于观察实际内存负担）；空闲唤醒、磁盘读写增量。RSS 包含共享页，不应直接作为独占内存或泄漏证据。指标不包括 WindowServer/GPU 和短命子进程，也不能代表全机能耗。

本机任务按每小时一次、每次 4 分钟检查，其余时间采样器不运行。属于周期采样，并非全天连续捕捉每个峰值；依赖机器唤醒和 Codex 本机执行环境可用。单次最多 10 分钟，间隔至少 1 秒，避免误启动高频或无期限采样。

## 分析与行动

- 对相同版本和同一 PID 比较，重启和升级重新建立基线；记录 CPU 均值、10 秒区间最大值、footprint/RSS 起止和峰值、唤醒率。10 秒均值不等于瞬时峰值。
- 观察至少一个 3 分钟刷新周期，并标记主动切换/展开等交互；冷启动和长期运行不能直接作同比。
- 单核 CPU 连续 60 秒超过 1%，或 footprint 连续三轮增加且合计超过 30 MiB，作为调查信号；这不是用户保证的性能上限，更不自动证明故障。
- 明确区分正常网络刷新和持续占用。确认异常后再进行一次短采样/调用栈调查，避免常驻 profiler、全量日志和持续轮询。
- 修改限于证据支持的性能/交互问题；运行 swift test、build-app、check-release、UI smoke，检查图像。保留用户工作，不关闭三个原应用、不改代理或系统安全设置。
- 本机更新须用签名公证构建；公开发布遵循现有发布流程。无异常时不发状态消息，只有确认异常、验证过的优化或需要用户输入时通知。

## 0.1.4 改动

- 移除全桌面鼠标移动监听，仅使用 AppKit 在应用自身区域的跟踪事件；全局鼠标监听已经不再承担当前常驻 UI 的必要功能。
- 布局变化只重新摆放按钮，避免每一帧重设图片、提示和辅助功能文本。
- 手动收起后，指针退出再进入才允许悬停展开，避免刚收起又弹出。
- 屏幕/系统休眠停止新额度查询；恢复后按原有间隔保护尝试更新。

长期趋势应保留原始本地 JSONL，不能凭单次 0.0% 快照宣称零占用或没有泄漏。

## 可重复的动画回归（0.1.6 后续测试补充）

`scripts/build-app.sh` 后执行 `scripts/test-animation.sh`。仅运行构建目录中的模拟应用，不替换安装版、不访问账户或网络。约 200 秒完成，250 秒看门狗兜底。需要短压力场景时，可直接运行构建目录可执行文件并传入 `--animation-test --interactions-only`（跳过真实三分钟轮换等待，不能替代完整测试）。请让测试窗口保持可见、避免主动操作测试窗口。启用减少动态效果或低电量模式时，正常动画覆盖检查会明确失败，不把未运行的动画算通过。

覆盖真实 60 秒定时器的三次轮换、12 轮展开/切换/收起、动画中模拟额度结果到达、快速反向操作、交互暂停、模拟休眠/唤醒、减少动态效果路径、单应用与空安装情况。测试日志只含场景名、耗时和断言结果。模拟休眠检查不等同于真实机器睡眠恢复；模拟结果到达不等同于在线网络端到端验证。

### 帧分析

先 `xcrun xctrace list templates` / `list instruments` 确认可用工具。对测试进程的明确 PID 使用 `Animation Hitches` 模板短采样，避免按同名应用启动导致选错安装副本。轨迹保存可能比采样本身慢，临时文件可能很大；不要作为常驻采样器运行。不要在 Instruments 运行时将资源数字作为无分析器干扰的基准。

导出指定表（不要输出整个 TOC，其中可能包含进程环境变量）：

```sh
xcrun xctrace export --input "$TRACE" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]' --output "$OUT/hitches.xml"
xcrun xctrace export --input "$TRACE" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches-updates"]' --output "$OUT/updates.xml"
python3 scripts/summarize-animation.py "$OUT" --pid "$TEST_PID"
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-animation-summary.py
```

只统计目标 PID。只有全桌面的 frame-lifetimes，而没有目标应用 updates 时，结果必须为 inconclusive；空 hitches 表不能证明零掉帧。显示器 vsync、主线程定时器、几何中间帧和 FPS 均值也不能替代逐帧呈现证据。原始 trace 只留本机，分享前仅导出脱敏统计，不提交仓库。

2026-09-09 本机工具限制：`Time Profiler` 加 `Core Animation FPS` 实际报错 “Disabled because macOS does not have an FPS metric for Core Animation.” 不再用该项作验收。`Animation Hitches` 在交互轨迹中能导出目标 PID 的更新和卡顿，因此用该项作卡顿证据；不要承诺一个未经测量的 60/120 FPS 数字。分析方法参见 [Apple：Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)。
