# Antigravity CLI Statusline 接入实施计划

**目标：** 在现有 CodexMeter 新增可选的官方 CLI 本地数据来源，并在原菜单栏/下拉/设置预览展示，保留旧功能及 Intel macOS 14 兼容。

**架构：** 原生轻量 Hook 解析官方 stdin JSON，以用户私有版本化文件作为唯一 CLI 观测；设置安装器只管理自有命令并用 bundle marker 防回滚误启动。UsageViewModel 在明确选中 CLI 时独立只读该文件，既有 UI 消费投影，Codex/Widget 共享缓存与通知不承载 CLI 数据。

**技术栈：** Swift、Foundation、SwiftUI/AppKit、XCTest、Xcode、现有 Intel 测试 CI。

**范围契约：** 以 [Final PRD](prd.md) 和 [已确认验收矩阵](acceptance-matrix.md) 为准。不得启动 CLI 后台查询、请求 Google、读凭据、自动覆盖第三方 Statusline，或重构其他供应商与正式发布。所有代码注释使用中文。

---

## 阶段 0：基线与影响分析（已执行）

- 刷新 GitNexus (`analyze --index-only`)；对变动符号执行 upstream impact。共享设置、UsageViewModel 刷新为 CRITICAL，额度卡/菜单显示为 HIGH；只改 Antigravity 专有分支并补回归。
- `bash script/test_release_version.sh` 和 `bash script/test_product_identity.sh` 已通过（后者使用本机已有 rg）；本机 `xcodebuild -version` 明确要求 Xcode，纯 Foundation 可用 Swift 5.1.3/x86_64 编译运行（目标 10.15，执行环境 14.6.1），XCTest 不可用。

## 任务 1：核心回调、快照与用户级安装（AG-01～04）

- 新增 `CodexMeter/AntigravityStatusline.swift`、`script/antigravity_statusline_checks.swift`、`script/test_antigravity_statusline.sh`，后两者使用合成夹具，先执行 RED。核心保持 Foundation/POSIX 兼容旧本机编译器，不依赖第三方运行时。
- 新核心 API：`AntigravityStatuslineFrame`（`capturedAt`、`accountEmail`、`planName`、`buckets`）；`AntigravityStatuslineBucket`（`id`、`remainingFraction`、`resetsAt`、`disabled`）；`AntigravityStatuslineStore(snapshotURL:)` 的 `receive(_:at:)`, `load()`；`AntigravityStatuslineHook.argument/run()`；`AntigravityStatuslineInstaller.status/install/remove`。
- 写失败测试：四桶精确值、`0/1` 与 epoch、错误类型/未知桶、同/未知账号空帧保留、不同账号空帧等待、部分替换、重复回调时间、坏帧/损坏文件、并发写、用户设置保全、第三方冲突、marker 缺失不执行、移除与自有修复。命令 `bash script/test_antigravity_statusline.sh`，RED 预期缺少功能，GREEN 预期全部 PASS；只写临时目录。
- 实现：严格 JSON 字段白名单，私有文件、有限输入、串行原子更新，不记录认证/原始输入；只有用户明确按钮安装/修复/移除自有命令，绝对路径 shell 安全引用。
- 新增 marker `CodexMeter/antigravity-statusline-v1.marker`，在 `CodexMeterMain.main` 正常 GUI 前分派；项目确保核心/适配器被主 app 与测试 target 编译，marker 被 app Resources 包含。

## 任务 2：来源偏好、投影、刷新与既有路径保护（AG-05～06）

- 先新增 `CodexMeterTests/AntigravityStatuslineTests.swift` 测投影、来源默认、Codex 共享缓存及通知；`UsageViewModelTests` 补本地源注入、网络失败、迟到任务、禁用、切换的测试（Xcode RED/GREEN，当前本机无法跑全 target，CI 必须执行）。
- 在共享偏好 `GeminiModelsSettings` 增加显式来源，默认历史来源，异常来源不触发请求。新增 `AntigravityStatuslineUsageClient.swift` 把合法当前帧映射到 `GeminiModelsSnapshot`；不跨源拼数据。读取旧文件绝不刷新 capture time；只显示有效未来 reset，过期不生成错误预测。
- `UsageViewModel` 按当前来源选择，代次/来源共同复核，CLI 本地读取独立于 Codex；既有共享 `UsageSnapshot` 不保存 CLI 值。本地刷新使用现有 cadence；手动档启动或显式操作读。设置预览通过独立变更通知重新用同一 reader 加载。`UsageNotificationController` 对新来源和早先在途旧源事件重新检查，CLI 不产生通知或彩带；旧 Codex 和历史来源行为保护。
- 运行可用核心测试，完整 Xcode 测试必须通过现有测试和新增测试；不得把未运行的 Xcode 断言描述为通过。

## 任务 3：现有 UI、marker、文档与工程（AG-07）

- `SettingsView` 新来源选择、明确安装/修复/移除状态，冲突不写其他配置；已有布局与开关原样。`GeminiModelsSection` 和菜单栏 Antigravity 投影显示来源、最后采集时间、可能过期/等待，未知或禁用不伪造 0%；仅 CLI 的过期预测/倒计时保护，不改其他供应商。使用现有本地化和 UI 样式。
- `CodexMeter.xcodeproj/project.pbxproj` 添加新文件及 marker 正确 target；`README.md` 补用户使用方法、边界、回滚说明。`plutil -lint CodexMeter.xcodeproj/project.pbxproj`、两基线脚本、核心测试、`git diff --check`。
- 独立代码审查覆盖真实边界、并发切源、配置保全、测试不依赖真实账号；按发现收口。外部 CC 计划评审：SKIPPED（当前工作流策略，用户未显式启用）。

## 任务 4：完整构建、安装和真实验收（AG-08）

- 已确认允许仅用户 fork 的 `codex/macos14-intel-test` 分支构建，不正式发布。使用已有 `.github/workflows/build-intel-test.yml`（不修改正式版本或 appcast），检查真实 workflow 测试结果与产物身份。
- 下载本次产物，校验 SHA256、`hdiutil verify`、签名、各 Mach-O 的 x86_64 与 minimum≤14；仅安装已验证的新包，保留可恢复的旧版和已有用户偏好。
- 新 app 设置选择本地 CLI 来源、显式安装回调，正常已登录 CLI 回调并对照真实 UI 与 `/usage`；不启动后台主动查询。必要时由用户正常重开 CLI。记录真实通过与未能覆盖部分，尤其官方空闲同步频率不承诺。

## 完成标准

- [ ] 核心 RED/ GREEN 与原有基线通过；所有改动符合 PRD，CLI 独立且不回退旧源。
- [ ] 完整 Xcode 测试、Intel 兼容构建通过，审查问题闭环。
- [ ] 安装的是本次版本并有实际 callback/可见额度证据，或明确剩余用户操作和缺口。
- [ ] 无正式 Release、上游推送或凭据/个人夹具进入仓库。
