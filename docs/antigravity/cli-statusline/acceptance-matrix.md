# Antigravity CLI Statusline 验收矩阵

- PRD：[Final PRD](prd.md)，基线 `035988c692cb0739b5226fe61c5a02f5693df83d`。
- 环境：本地 Intel macOS 14.6.1；已登录官方 `agy` 1.5.18。该独立 macOS 工具无 Corevo QA 用例，不接触其他项目或生产环境。
- 状态：2026-11-26 用户已确认全部 E2E 场景、数据与验收方式；已明确授权本次仅 fork 测试分支 commit + push（不发布正式 Release）。真实账号数据不写入仓库；模拟场景全部用以下人工构造的合成值。
- 范围：新增官方 CLI 回调、原子本地快照、来源切换和现有 UI，保护 Codex、旧 Antigravity、通知、Widget、其他设置及 macOS 14 Intel。未确认官方实时性、CLI 空闲时的 provider 更新频率不是验收承诺。

## 质量与覆盖

| 类型 | 用例 | 说明 |
| --- | --- | --- |
| 单元/本地进程 E2E | AG-01～AG-04 | 使用真实读写、原生回调入口及临时设置文件；本机 Swift 5.1 的 Foundation 核心测试可运行。 |
| 完整 target 测试、前后对比 | AG-05～AG-07 | 使用实际 Xcode 测试，模拟网络客户端并断言调用次数；当前本机 Xcode 不可用，需可用现代 Xcode 环境。 |
| 真实 GUI E2E | AG-08 | 安装本次构建的 Intel/macOS 14 包；用户正常 CLI 回调，不额外发送模型提示；对照 CLI 与 UI。 |

## 覆盖决策确认

| 决策点 | 当前理解 | 选项 | 推荐 | 下游影响 | 用户结论 |
| --- | --- | --- | --- | --- | --- |
| 自动化测试与真实设备 | 用户已完成官方 CLI 登录；使用合成夹具覆盖边界，实际回调来源由用户正常 CLI 产生 | A 核心本地测试 + 完整 Xcode + 本机真实 GUI；B 仅测试逻辑，真实包后续验收 | A | 用户可以对照 `/usage`，不发模型请求。 | 已确认（选项 A） |
| 完整构建来源 | `xcodebuild` 因仅 CLT 失败；必须另有现代工具链，现有 fork 测试 workflow 已支持 Intel | A 明确授权本次仅测试分支提交/推送触发 CI（不发布）；B 不提交推送，仅本地验证，完整装包等待后续授权 | A | 不改变正式发布；B 不得声称已安装新 App。 | 已确认（选项 A） |

## E2E 场景与数据确认

合成时间 `T=2026-11-26T09:00:00Z`，账号 A `a@example.invalid`，B `b@example.invalid`，均非真实账号。所有入口只使用官方公开字段。

| 场景 | 要证明的行为 / 触发 | 独立真值与精确测试数据 | 检查点及逐字段期望 | 不变量 / 失败判定 | 用户结论 |
| --- | --- | --- | --- | --- | --- |
| AG-01 四窗口 | 向原生回调输入一份官方形态 JSON，再由真实读取器加载 | A、Google AI Pro；`gemini-5h=.72, reset=T+7200`；`gemini-weekly=.96, reset=T+345600`；`3p-5h=1, reset=1970-01-01`；`3p-weekly=.50, reset=T+518400` | 文件仅可信字段，映射 Gemini 72/96、Claude/GPT 100/50，各 5h/7d；3p-5h 无有效 reset；时间=T，source=CLI | 四桶无互换、无拼接；重复读取不改变采集时间；任一比例/时间错误或记录原始 JSON 即失败 | 已确认（选项 A） |
| AG-02 无效/空/切换 | 先 AG-01，再依次送同账号空帧、未知身份空初始化、B 空帧、B 有效部分帧 | A 全部有效（AG-01）；A/未知空；B 新身份空；B `gemini-5h=0`，`3p-weekly.disabled=true`，`gemini-weekly.remaining_fraction=true`，未知桶及只有 amount=42 | 前两空帧保留 A 与 T；B 空帧清掉 A 读数，等待；B 有效帧只显示已知当前值，0 为 0%、禁用为不可用、非法或 amount-only 不伪造 0；身份/套餐不借用 A | 文件始终一份，失败/空同身份不刷新旧时间，切换不混账号，不能把 epoch 或未知值转为可用额度 | 已确认（选项 A） |
| AG-03 原子、失败与陈旧 | 多线程/进程写独立临时目录；损坏/缺失/非本版本；按 T+121s、重置已到及回拨 T-1 检查 | 两组可区分数据 A/B；非 JSON、超限、错误 product；`capturedAt=T`、重置=T+60 | 读者只见完整接受帧；拒绝坏输入不覆旧；未知文件版本、权限/损坏显示错误（不读旧源）；采集时间不变；陈旧或未来时间不称新鲜，已过 reset 不称已重置且不显示 Pace/ETA | 无部分 JSON/串桶/无限等待；重复回调可更新时间但读不更新时间；不发后台请求 | 已确认（选项 A） |
| AG-04 安装回调与降级 | 对临时用户 settings JSON 安装、重复、修复、移除；存在他人命令和无 marker 的旧 app | `theme="dark"`、`permissions`/无关键；预置另一个 `statusLine.command`；测试执行路径含空格和单引号；移除 marker 后触发 command | 正常只增加自有 `statusLine`，`type=command,enabled=true,stack_with_default=true`；未安装/已安装/冲突正确；第三方配置原样、移除只去自有块；缺 marker 不执行旧二进制 | 配置其余键逐项相等；不访问真实设置及登录；假的旧执行计数=0；安装失败不报告成功 | 已确认（选项 A） |
| AG-05 来源、无网络耦合 | ViewModel 注入计数旧源/本地源与失败 Codex 客户端；启动、手动刷新、源切换、关闭 | 旧源快照 L=Gemini 33%；CLI C=AG-01；Codex 预存值例如 42/84%，失败模拟；切回继续 L | CLI 已启用时显示 C、旧源调用次数=0、Codex 失败也发布；迟到 L 不覆盖 C；关闭隐藏；切回 L 不能用 C；共享缓存保持原 Codex，与 CLI 文件分开 | CLI 不写新的共享枚举/数据，主动读不调用 CLI/Google，现有旧源行为及 Widget 不变 | 已确认（选项 A） |
| AG-06 提醒与保护性回归 | 现有通知/重置检测与新来源窗口；先基线再同一测试 | 旧来源从 30% 到 0%、重置测试已有样例；CLI 从 72% 到 0；Codex 测试已有样例 | 旧来源/Codex 原断言相同；CLI 不触发 Antigravity 通知/彩带或影响 Codex；切换后旧在途比较只建基线 | CLI 通知数=0、旧源/Codex 受保护行为与基线一致 | 已确认（选项 A） |
| AG-07 展示/持久化 | 用 AG-01 和 AG-03 派生 `GeminiModelsSnapshot` 测菜单栏、预览、下拉；源关闭与禁用 | AG-01 及 `now=T+121s`，过期 reset、缺失比例 | 既有布局/组筛选读取 CLI；真实 0/100、无效 reset 无“已重置”；来源与采集时间可见、过期提示，不伪造 0，不改 Codex、Go、Widget 配置 | 字段与 AG-01 一致，过期不继续推算；旧设置默认旧来源 | 已确认（选项 A） |
| AG-08 真实本机 | 用本次构建包替换/启动 App，从设置选 CLI 并由用户显式安装回调，必要时正常重开已登录 CLI，输入 `/usage` 或等其正常回调 | 独立真值：同一时刻官方 CLI 面板的真实账户额度；不把实际个人值写入仓库。此前已验证四桶存在 | 校验实际包架构 x86_64、minimum≤14、签名、版本标识；真实 callback 文件中有效桶与 CLI 读数一致；下拉及菜单栏显示相同组值、时间和来源；停止更新后显示缓存可能过期；禁用、移除不影响 Codex | 只凭真实 callback/UI 证据确认；仅编译/脚本通过不是已装包或视觉验收。不主动启动 CLI 批量查询，不生成模型消息 | 已确认（选项 A） |

## 跨里程碑字段完整传递矩阵

| 字段 | 分类 | 独立原始值（AG-01/02） | 本地快照 | 映射消费端 | 最终不变量 |
| --- | --- | --- | --- | --- | --- |
| `product` | must-change | `antigravity` | 合法输入才写 | 固定 CLI 来源 | 非 Antigravity 拒绝 |
| `quota.gemini-5h.remaining_fraction` | must-change | `.72`/`0` | 0.72/0 | group Gemini/5h | 72%/0% |
| `quota.gemini-5h.reset_time` | must-change | `T+7200` | 合法绝对时间 | Gemini/5h reset | 2h，时钟越界不声称重置 |
| `quota.gemini-weekly.remaining_fraction` | must-change | `.96`/`true` | 0.96/nil | Gemini/7d | 96%/未知 |
| `quota.gemini-weekly.reset_time` | must-change | `T+345600` | 合法绝对时间 | Gemini/7d reset | 4 天 |
| `quota.3p-5h.remaining_fraction` | must-change | `1` | 1 | Claude/GPT/5h | 100% |
| `quota.3p-5h.reset_time` | must-change | epoch | nil | reset 不可用 | 不显示 1970/已重置 |
| `quota.3p-weekly.remaining_fraction` | must-change | `.50` | 0.50 | Claude/GPT/7d | 50% |
| `quota.3p-weekly.reset_time` | must-change | `T+518400` | 合法绝对时间 | Claude/GPT/7d reset | 6 天 |
| `quota.3p-weekly.disabled` | must-change | true（AG-02） | true | 不可用窗口 | 不计为 0% |
| `quota.*.remaining_amount` | must-change | 42，未给分母 | 不传递（没有比率） | 无百分比 | 不猜测 |
| `email` | must-change | A/B/缺失 | 可选当前来帧，等待态可为空桶 | 当前账号标识 | 不借用别的账号 |
| `plan_tier` | must-change | `Google AI Pro` | 可选当前来帧 | planName | 不借旧套餐 |
| `capturedAt` | derived | `T`（注入本机接收时钟） | 原样 | fetchedAt | 重读不变化；120 秒过期阈值、未来时间不新鲜 |
| `source` | must-change | 官方来帧 | 独立文件 | `.antigravityCLIStatusline` | 不进共享快照 |
| `UsageSnapshot.rateLimits` | must-protect | 42/84（AG-05）及原测试值 | 不传给 CLI 文件 | 共享 Codex 路径保留 | 与基线语义相等 |
| `UsageSnapshot.geminiModels`（旧源） | must-protect | L=33%/历史模型 | 仅旧值或 nil | 只在旧来源消费 | 不出现 CLI 枚举或数据 |
| `statusLine.command/type/enabled/stack_with_default` | must-change | 非自有时拒绝；含引号绝对路径 | `command`、true、true | CLI 正常委托 | marker guard；不启动旧程序 |
| 其他 CLI 设置、登录、对话字段 | must-protect | 合成无关键值 | 保留设置；回调中不存储 | 不传递到额度面板 | 无外发、无原始 JSON |

## 验收执行计划

| 阶段 | 命令/动作 | 期望 | 证据 |
| --- | --- | --- | --- |
| baseline | `bash script/test_release_version.sh`；`bash script/test_product_identity.sh`（PATH 含已存在 rg）；`xcodebuild -version`；Swift 5.1 基础 Foundation smoke | 两脚本通过；本地 Xcode 不可用已经确认；不伪造基线 UI | 本会话终端输出；基线 SHA |
| core RED/GREEN | `bash script/test_antigravity_statusline.sh` | 初次针对缺失功能失败；实现后所有 AG-01～04 测试通过；失败不覆盖真实用户配置 | 本会话终端输出；合成数据测试源码 |
| Xcode 单元/组件 | `xcodebuild -project CodexMeter.xcodeproj -scheme CodexMeter -destination 'platform=macOS' MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO test` | AG-05～07、既有测试 0 失败 | 完整 CI test 日志/xcresult；本地无 Xcode 时明确待验证 |
| after/compare | 重跑基线脚本、`git diff --check`、项目 plist 检查及现有 test suite | 受保护断言与基线相同；代码无范围外变更 | 本会话终端输出及审查记录 |
| build | 若授权，使用既有 `构建 macOS 14 Intel 测试包` workflow；校验产物 SHA256、签名、Mach-O 和 minimumOS | 主 app 和 framework/Widget 均 Intel/macOS14，正确的改动 commit，不发正式 Release | GitHub Actions 测试 artifact、checksum 与本机验证 |
| GUI E2E | 在新安装包设置页装回调，用已登录官方 CLI 的正常操作捕获 AG-08，打开菜单/下拉；只记录脱敏结果 | 生效、实际数字等价、源及时间正确；退出/陈旧情况不假装实时 | 本机真实 UI 操作证据；如需用户点按明确指出 |

不覆盖：桌面版专用探测、CLI 空闲主动刷新供应商、旧私有协议修复、未知未来桶、第三方脚本组合、其他应用或生产工作。仅在 UI E2E 暂不可执行时提供已验证核心与待验收边界，不宣称任务已交付。
