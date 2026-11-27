# Antigravity 优先仪表盘实施计划

**目标：** 提供默认 Antigravity 的供应商下拉页、可靠的本机已记录 Token 与 API 等效费用、五分钟本地检查。

**架构：** Foundation-only reader 只读 Powertools 已有桌面事件和价格缓存，聚合为无身份/正文的日和模型事实。独立 app-only ObservableObject 拥有用量状态与五分钟读取，复用现有 CLI 额度分支以及现有各供应商视图；弹窗显示选择由真实打开边界控制。

**技术栈：** Swift 6、SwiftUI/AppKit、Foundation、现有 Xcode 目标；Foundation 核心兼容本机 Swift 5.1 测试。

**范围契约：** [Final PRD](prd.md)、[用户已确认的验收矩阵](acceptance-matrix.md)。不改变既有 Codex/Go/Widget 共享数据和价格引擎，不改插件及其文件、不加网络/凭据读取或服务端额度伪更新。CC 额外计划评审未启用。

---

## 任务 0：固定基线（已取得证据）

- 依据 PT-05：已运行 `bash script/test_antigravity_statusline.sh`（6组）、`test_release_version.sh`、`test_product_identity.sh`、`plutil -lint CodexMeter.xcodeproj/project.pbxproj` 全部通过；基线完整 XCTest 来自前一轮成功 CI。本轮完整结果由新 CI 获得，不能把本地核心当全编译。
- GitNexus 索引刷新，关键旧符号 impact 已完成并向用户提示 HIGH/CRITICAL；每个额外现有符号修改前补影响分析。

## 任务 1：真实数值解析、聚合与文件契约（PT-01/02）

- 新建 `script/antigravity_powertools_checks.swift` 与 `script/test_antigravity_powertools.sh`；针对 `Now=2026-12-01T01:00Z` 的上海日期与 UTC 变价构造合成缓存文件。断言 `snapshot.summary(.today).totals` 为 2条、6300000 tokens、15.40 USD、cacheHit=0.5；`sevenDays` 3条、13600000、29.50，重复 a 不加倍。另覆盖冲突 ID、未知/零/非法三桶、缺价/坏价、空/损坏/超限、符号链接/读取不修改 bytes。
- 运行 `bash script/test_antigravity_powertools.sh`，先要求缺失实现导致 RED。新增 `CodexMeter/AntigravityPowertoolsUsage.swift`：固定两文件的有界普通文件读取、严格白名单结构、`PowertoolsUsageReader`、`PowertoolsUsageSnapshot`、`PowertoolsUsagePeriod`、`PowertoolsUsageTotals` 等小型数据结构。按事件定价后聚合；请求ID仅局部去重；读取不产生副作用。以实际字节/时间戳与价格日期独立公式为验收，不输出真实记录。
- 反复运行新脚本直到全绿，再运行原6组核心；禁止借机重构原 reader/共享模型。

## 任务 2：本地刷新状态和 CLI 观测语义（PT-03/05）

- 新增 `AntigravityPowertoolsStore.swift` 与组件 XCTest `AntigravityPowertoolsTests.swift`：独立 opt-in（默认关）、总开关停用、同源并发合并、迟到结果拒绝、缺价与缺记录分离、五分钟自动/手动无定时、开启/启动/打开/手动检查。通过注入临时 reader/时钟和隔离 UserDefaults 验证，不触发旧源或共享缓存。
- 修改经影响分析的 `UsageViewModel.swift`/`AntigravityStatuslineUsageClient.swift`：只调整 CLI 独立 cadence 为300s、增加上次本地实际检查时间并保留真实 fetchedAt；合并 CLI 重入、source generation/reset 仍正确。更新 `AntigravityStatuslineTests.swift` 的120秒专属阈值为300秒并增加299/300、检查时间和源隔离测试。旧来源/Codex cadence 原样。
- 本地 `xcodebuild` 若因 CLT 失败，记录此限制；全部 XCTest 在 CI 执行，现有脚本必须本地通过。

## 任务 3：供应商 Tab 与真实统计视图（PT-04/06）

- 新建 app-only `PopoverProviderSelection.swift`（真实打开时默认，合法选择保留、隐藏降级）和 `AntigravityPowertoolsViews.swift`（数据/时间/缺失/模型细分/趋势）；新增 selection 生命周期测试，不在 SwiftUI 渲染/测量副本发起 I/O。
- `CodexMeterApp.swift` 保留选中状态跨宿主重建、真实 show 时 reset 并独立本地读取；`MenuBarView.swift` 顶部固定 Tab、选中账号/状态、分组复用 Codex/Go/CLI 卡、刷新/底栏保全；`QuotaWindowView.swift` CLI 显示独立检查时间/真实观测/提示。`SettingsView.swift` 通过同一 app store 显示 opt-in 与详细统计，打开时请求读取。适配中英文本及工程 app/test targets（Widget/shared 缓存不引入这些类型）。
- 先写 PT-03/04 的组件测试与既有阈值断言，后实现。用同一 source store 测试关闭时不读，切换/重开选择不触发网络；真实 UI 由安装后的设备确认。

## 任务 4：整体验证、审查与装包（PT-01～06）

- `bash script/test_antigravity_powertools.sh`、`bash script/test_antigravity_statusline.sh`、发布/产品身份脚本、`plutil -lint ...`、`git diff --check`，检查 app/test target 引用、新增文件中文注释，GitNexus detect_changes 范围。独立代码审查，修复明确当前范围问题并重新验证；不扩展到邻近清理。
- 使用既有授权测试分支 CI `build-intel-test.yml`，先完整 `xcodebuild ... MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO test` 0失败，再 Intel Release 与所有二进制最低OS/签名校验。日志和产物对应最终 SHA；本机核对 ZIP/DMG SHA256、hdiutil verify、codesign、Mach-O、备份旧 app 后安装并实际启动。真实数据按同一桌面缓存代次/本地期间/UTC价独立计算，用户目测下拉/重开；不要求真实 Token 增量由 Agent 主动请求，不保证无 CLI 新事件时额度服务端更新。

## 执行说明

当前会话串行执行；任务1的类型是任务2/3契约前提，避免并行改共享 UI 导致冲突。本轮已获用户确认实施、验收和 fork 测试授权；本实施计划不含提交步骤。所有待确认行已收口。未覆盖的上游完整桌面额度/账号/历史导出留作后续；不发布正式 Release。
