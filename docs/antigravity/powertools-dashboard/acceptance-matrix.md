# Powertools 仪表盘验收矩阵

- 意图：[Final PRD](prd.md)，基线 `a4f7199aa6eb8c4b216f4044c2c6d8ed9bea2c62`，本机 Intel macOS 14.6.1。个人 OSS 工具，无 Corevo QA 依赖、服务器或组织账号；所有自动化测试使用合成数据和临时文件，真实已获授权的桌面 E2E 只读现存统计。不读取其他项目或私有环境来源。
- 状态：用户已明确按本矩阵验收（2026-11-27），采用合成固定数据、完整 XCTest 与本机真实 E2E。本次测试分支 commit/push、CI、安装已由用户确认；不发布 Release。
- 范围：Final PRD 的供应商 Tab、桌面计量、五分钟检查、真实来源；保护 Codex/Go/Widget/旧源、回调和所有非统计文件。不实现桌面实时额度、账号账本或第三方插件修改。

## 质量目标、环境与覆盖

| 维度 | 场景 | 环境与证据 |
|---|---|---|
| 自身功能可用 | PT-01～PT-04 | Swift Foundation 本机合成真实文件读取/聚合/价快照；完整 app XCTest 组件、生命周期和下拉选择；CI `MACOSX_DEPLOYMENT_TARGET=14.0`。 |
| 保护性回归 | PT-03～PT-05 | 前后运行已有核心、全部 XCTest、发布/产品身份检查；旧源无新请求、共享文件无新字段，选择不改变供应商开关。 |
| 真实设备链路 | PT-06 | 下载已核验 exact commit Intel 包，签名/架构/最低系统、实际安装和重开 app。用户已使用、正常更新 Powertools；比较同一份本机统计文件、同一时间窗口/日期价，不读对话或新增模型请求。受系统 UI 辅助功能权限限制时用户截图/操作作为原生 UI E2E，核心数字另用独立只读计算验证。 |

## 精确场景与数据

固定本地时区 `Asia/Shanghai`，`Now=2026-12-01T01:00:00Z`；合成价格 `gemini-4-carbon` 每百万 USD 新输入2/缓存0.1/输出10，`until=2026-12-01`、`next` 4/0.2/20；`gemini-4-neon` 3/0.15/15。下列值与真实个人记录无关。

| ID | 触发与数据 | 独立真值 / 检查点 | 失败判定 | 用户结论 |
|---|---|---|---|---|
| PT-01 | 临时 usage/price 缓存；a=11-30T23:59:59.125Z Carbon (High), new1M/cache2M/output0.1M；b=12-01T00:01:00.250Z Carbon (Medium), new2M/cache1M/output0.2M；c=11-30T14:00Z Neon, new3M/cache4M/output0.3M；a 重复。 | 日期按上海，UTC 单价切换：a=3.20、b=12.20、c=14.10 USD。今日/12月 2条、6.3M、15.40、命中50%；近7天/保留3条、13.6M、29.50、命中7/13；模型 Carbon 6.3M，Neon 7.3M。读取不改文件。 | 小数时间被丢弃、日期/价跨界错、重复加倍、缓存或 thinking 复加、金额不等。 | 已确认（按此验收） |
| PT-02 | 在合成数据上加入未知模型 u（400/500/600），真实零 z（0/0/0），同 ID 两条冲突、Bool/缺桶/异常时间，坏价/缺价/重复冲突价、空数组、坏 JSON、超限、符号链接。 | 合法零保持0；u Token保留但金额未知（已计金额为部分）；冲突整组剔除，错误行数可核对；空时段不声称全量0；价格读失败仍有合格 Token；损坏/路径不安全明确失败。读取只限两个指定文件，哈希不变。 | 伪造零、first/last-wins冲突、未知价套其他模型、异常源外读取、修改插件/保留原文。 | 已确认（按此验收） |
| PT-03 | 已启用统计和 CLI；使用注入的读取/睡眠时钟，启动、打开/手动、30s/60s/5m 自动与 manual、并发触发、关闭/切源后晚到完成；CLI 合成观测T。 | 自动本地间隔=300s，manual 无后台读；并发同源合并，关闭后旧结果不发布；Codex 仍原 cadence。读取旧 CLI 文件只更新 lastCheckedAt，capturedAt 不变；T+299新鲜，T+300过期，未来时间非新鲜；重置边界不显示伪重置；价和额度失败不互相阻塞。 | 轮询/启动供应商、修改真实观测、反复读取、迟到数据越代发布、影响 Codex/Widget/通知。 | 已确认（按此验收） |
| PT-04 | Mac 下拉实际打开、切 Codex、刷新和偏好重建、关闭/reopen、禁用 Antigravity、启用/隐藏Go；设置详细统计。 | 可见页 `[Antigravity,Codex,(Go)]`；每次真实打开默认 Antigravity，关闭后 fallback Codex；打开期间合法选择保留；额度第一，费用/Token同一发布，选中页账号与错误不串家，滚动/底部按钮正常；Tab 不启动请求。 | 单列/错序、隐藏开关失效、刷新抢页、两个预览不同事实、Codex/Go内容丢失。 | 已确认（按此验收） |
| PT-05 | 现有 CLI AG-01～08 核心/XCTest、Codex/Go/Widget 测试和发布脚本在最终提交重跑。 | 原四桶数据、安装保全、源切换、Codex 数值与成本/通知、Widget旧格式均维持；仅 CLI 陈旧边界调整为300秒。Powertools 默认关闭，无真实文件读取、旧额度请求/共享缓存改动。 | 任一原契约意外失败、CLI或新统计入共享缓存、额外认证/请求或无关改动。 | 已确认（按此验收） |
| PT-06 | 安装此轮 exact commit 的 Intel 包；启用用户已批准的 Powertools 统计；正常打开 Antigravity Tab，切换 Codex 后重开；随用户正常桌面活动/既有插件更新读数，手动或五分钟检查；无额外模型消息。 | 产物 SHA、签名、所有 Mach-O x86_64/最低系统≤14；本机只读独立公式重算同一缓存代次的今日/月/保留值和覆盖；GUI 额度位置/来源/时效/费用一致。CLI 无新观测则明确旧时间，不承诺全账号或 Powertools 混合看板一致。 | 未安装当前包、检查时间冒充配额观测、与同代数值不符、无数据伪造、用户需改插件/凭据。 | 已确认（按此验收） |

## 字段传递与保护

| 来源叶字段 | 分类 | 合成独立值 | Reader/汇总 | 最终展示或不传递 | 场景 |
|---|---|---|---|---|---|
| `id` | must-change | a 重复、x 冲突 | 仅内存去重 | 不传递、不持久化 | PT-01/02 |
| `timestampMs` | must-change | a 的 .125 毫秒精度 | Date；上海日期与UTC费率日 | 12月当日、价为旧档；显示覆盖 | PT-01 |
| `model` | must-change | Carbon (High)/(Medium), Neon, unknown | 精确标准化 | 模型汇总，未知仍计Token | PT-01/02 |
| `inputTokens` | must-change | a=1M | newInput=1M | 今日3M | PT-01 |
| `cacheReadTokens` | must-change | a=2M | cachedInput=2M | 今日3M、50% | PT-01 |
| `outputTokens` | must-change | a=.1M | output=.1M | 今日.3M，不加thinking | PT-01 |
| `rates[].model` | must-change | gemini-4-carbon | 精确匹配 | 仅匹配记录定价 | PT-01/02 |
| `rates[].input` / `next.input` | must-change | 2 / 4 | 依UTC事件日 | a贡献2、b贡献8 | PT-01 |
| `rates[].cache` / `next.cache` | must-change | .1 / .2 | 依UTC事件日 | a贡献.2、b贡献.2 | PT-01 |
| `rates[].output` / `next.output` | must-change | 10 / 20 | 依UTC事件日 | a贡献1、b贡献4 | PT-01 |
| `rates[].until` | must-change | 2026-12-01 | UTC截止日(不含) | 不用本地日期提前变价 | PT-01 |
| `checkedAt` | must-change | 固定有效日期 | 价目录观察日期 | 重读不改价更新时间 | PT-01/02 |
| `usageFile.modifiedAt` | must-change | T-17s | 原文件 mtime | 数据源更新时刻 | PT-03 |
| `lastCheckedAt` | derived | T+300s | 实际读取完成 | 与原采集分开 | PT-03 |
| `summary.totalTokens` | derived | 6.3M / 13.6M | 三桶相加 | 今日/7天真实去重 | PT-01 |
| `summary.estimatedCostUSD` | derived | 15.40 / 29.50 | 请求计价再求和 | 部分、未知或有效0区分 | PT-01/02 |
| `validCount/pricedCount` | derived | 今日2/2、u未计价 | 覆盖质量 | 计价覆盖说明 | PT-01/02 |
| `CLI.capturedAt` | must-protect | T | 原文件记录 | T 不被本地检查覆盖 | PT-03/05 |
| `UsageSnapshot.rateLimits/localCodexUsage/geminiModels` | must-protect | 原回归夹具 | 原调用路径 | 不含新桌面统计或CLI新字段 | PT-05 |
| 正文/会话/错误/凭据 | must-protect | 无关合成哨兵 | 不纳入字段 | 不传递/写入/外发 | PT-02/05 |

## 执行与证据

- Baseline：本会话 `test_antigravity_statusline.sh` 6组、`test_release_version.sh` 与 `test_product_identity.sh` 已通过，工程 plist lint。After：新纯 Foundation `test_antigravity_powertools.sh` + 同一基线脚本；CI完整 XCTest（包含新组件与生命周期测试）；GitNexus detect_changes、独立整体审查。
- Compare：不在旧价格引擎、共享 UsageSnapshot、Widget、Go/旧供应商接口内加入功能路径；新默认关闭开关不触发旧通知。验收实际新包、用户界面以及只读数值对比证据。本机证据留在现有本地任务环境/临时私有目录，下拉截图只由用户提供或明确授权；仓库仅合成夹具、脱敏方案及可运行测试。不随提交保存真实个人请求 ID、模型组合、账单/额度数据。
- 不覆盖：底层完整历史、账号归属、桌面完整实时额度、相邻业务系统、真实第三方接口调用；按确认的非目标延后。没有真实 UI/安装证据不得声称已交付。
