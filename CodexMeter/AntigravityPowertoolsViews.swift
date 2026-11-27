// Antigravity 本机桌面记录的只读展示；弹窗与设置消费同一发布结果，不访问文件、账号、网络或插件。
import CodexMeterShared
import SwiftUI

/// 新增 Antigravity 文案沿用应用语言偏好，避免系统区域设置与已选界面语言不一致。
func antigravityText(_ chinese: String, _ english: String) -> String {
    AppLocalization.usesEnglish() ? english : chinese
}

/// 两种展示面共用的本地文件检查说明；它不是主动刷新服务端额度的承诺。
let antigravityLocalCheckExplanation = (
    chinese: "自动档每 5 分钟检查已启用的本地文件；手动档仅启动、打开或显式刷新时检查。",
    english: "Automatic mode checks enabled local files every 5 minutes; manual mode checks only at launch, open or explicit refresh."
)

/// 统一显示精确计量、可读日期以及部分/未知计价；不从其他供应商推算金额或用量。
private enum PowertoolsDisplay {
    /// 期间选择保持核心四种口径，保留记录明确不等于账户终身用量。
    static func periodTitle(_ period: PowertoolsUsagePeriod) -> String {
        switch period {
        case .today: return antigravityText("今日", "Today")
        case .sevenDays: return antigravityText("近 7 天", "7 days")
        case .month: return antigravityText("本月", "Month")
        case .retained: return antigravityText("保留记录", "Retained")
        }
    }

    /// 整数按地区分组显示，避免缩写舍入妨碍使用者核对实际 Token。
    static func number(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = currentAppLanguage().locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 无已计价记录显示破折号；微小非零费用保留小数或上界，不显示成免费。
    static func cost(_ totals: PowertoolsUsageTotals) -> String {
        guard let value = totals.estimatedCostUSD, value.isFinite, value >= 0 else { return "—" }
        let amount: String
        if value > 0 && value < 0.000001 {
            amount = "< $0.000001"
        } else {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = value > 0 && value < 0.01 ? 6 : 2
            amount = formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
        }
        return totals.pricedRecordCount < totals.recordCount
            ? "\(amount) · \(antigravityText("部分", "Partial"))"
            : amount
    }

    /// 比例为核心加权命中率；实际没有输入时返回未知而非 0%。
    static func hitRate(_ totals: PowertoolsUsageTotals) -> String {
        guard let rate = totals.cacheHitFraction else { return "—" }
        return String(format: "%.1f%%", rate * 100)
    }

    /// 所有时刻用快照读取时的本地时区显示；跨系统时区变化时仍能解释原分组。
    static func date(_ date: Date?, calendar: Calendar, includesTime: Bool = true) -> String {
        guard let date = date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = currentAppLanguage().locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = includesTime ? .medium : .none
        return formatter.string(from: date)
    }

    /// 只转换读取器预定义的脱敏诊断；未知文案使用通用状态，不附带第三方文件内容。
    static func notice(_ message: String) -> String {
        switch message {
        case "等待 Powertools 生成本机用量记录。":
            return antigravityText(message, "Waiting for Powertools to create local usage records.")
        case "Powertools 本机文件不可读或类型不安全。":
            return antigravityText(message, "Powertools local data is unreadable or not a safe file type.")
        case "Powertools 本机统计超过读取上限。":
            return antigravityText(message, "Powertools local statistics exceed the read limit.")
        case "Powertools 统计格式无效，等待有效记录。":
            return antigravityText(message, "Invalid Powertools data. Waiting for valid records.")
        case "Powertools 正在更新记录，请稍后刷新。":
            return antigravityText(message, "Powertools is updating its records. Please try again later.")
        case "未获得有效模型价格。":
            return antigravityText(message, "No valid model prices are available.")
        case "部分模型价格缺失或冲突。":
            return antigravityText(message, "Some model prices are missing or conflicting.")
        default:
            return antigravityText("当前 Powertools 数据不可用或不完整。", "Current Powertools data is unavailable or incomplete.")
        }
    }
}

/// Powertools 卡片只在调用方明确显示时渲染；时间、期间及折叠均由上层传入，隐藏测量副本和实际界面一致。
struct AntigravityPowertoolsSection: View {
    @ObservedObject var store: AntigravityPowertoolsStore
    @Binding var period: PowertoolsUsagePeriod
    @Binding var detailsExpanded: Bool
    let compact: Bool
    let now: Date

    /// 未启用、未读取、读取失败、成功空及成功非空都有独立文案，不能用零值填充缺失状态。
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(antigravityText("本机消耗与成本", "Local usage & cost"), systemImage: "chart.bar.xaxis")
                    .font((compact ? Font.caption : .callout).weight(.semibold))
                Spacer(minLength: 4)
                Text("Powertools")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(antigravityText("正在检查本机统计", "Checking local usage"))
                }
            }
            Text(antigravityText("本机桌面记录 · 不按账号归属", "Local desktop records · not attributed to an account"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !store.isEnabled {
                Text(antigravityText("可在设置 → Antigravity 中启用 Powertools 本机用量统计。", "Enable Powertools local usage in Settings → Antigravity."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let snapshot = store.snapshot {
                usage(snapshot)
            } else {
                waitingStatus
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .menuSectionCard(padding: compact ? 8 : 12)
    }

    /// 读取尚未完成或本轮失败；失败时只显示最后检查时间，不生成虚假的文件更新时间或金额。
    private var waitingStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = store.errorMessage {
                Label(PowertoolsDisplay.notice(error), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if store.isRefreshing {
                Text(antigravityText("正在读取本机统计…", "Reading local usage…"))
            } else {
                Text(antigravityText("等待 Powertools 本机记录。", "Waiting for Powertools local records."))
            }
            metadataRow(antigravityText("最近本地检查", "Last local check"),
                        PowertoolsDisplay.date(store.lastCheckedAt, calendar: .current))
            if store.errorMessage != nil {
                Text(antigravityText("本轮未取得有效统计，不代表消耗为零。", "No valid statistics in this check; this does not mean zero usage."))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 当前缓存中的日、周、月及保留记录均为同次统计；纯显示时钟可以跨日重新选区间，不增加读取。
    private func usage(_ snapshot: PowertoolsUsageSnapshot) -> some View {
        let summary = snapshot.summary(for: period, now: now)
        return VStack(alignment: .leading, spacing: 8) {
            Picker(antigravityText("统计区间", "Usage period"), selection: $period) {
                ForEach(PowertoolsUsagePeriod.allCases) { option in
                    Text(PowertoolsDisplay.periodTitle(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(compact ? .small : .regular)
            .accessibilityLabel(antigravityText("统计区间", "Usage period"))

            Text(periodDescription(calendar: snapshot.calendar))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if summary.totals.recordCount > 0 {
                overview(summary.totals)
            } else {
                Text(antigravityText("当前记录无该时段数据，不能确定消耗为零。", "No records for this period; zero usage cannot be assumed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if compact {
                DisclosureGroup(antigravityText("模型细分与近 7 天趋势", "Models & 7-day trend"), isExpanded: $detailsExpanded) {
                    detailContent(snapshot: snapshot, summary: summary)
                        .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
            } else {
                detailContent(snapshot: snapshot, summary: summary)
            }

            Divider()
            sourceDetails(snapshot)
        }
    }

    /// 明确本地日历日期和读取时区；保留记录模式不称累计账本。
    private func periodDescription(calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let start: Date?
        switch period {
        case .today: start = today
        case .sevenDays: start = calendar.date(byAdding: .day, value: -6, to: today)
        case .month: start = calendar.dateInterval(of: .month, for: today)?.start
        case .retained: start = nil
        }
        let range: String
        if let start = start {
            let endText = PowertoolsDisplay.date(today, calendar: calendar, includesTime: false)
            let startText = PowertoolsDisplay.date(start, calendar: calendar, includesTime: false)
            range = start == today ? endText : "\(startText) – \(endText)"
        } else {
            range = antigravityText("本份缓存 · 非生命周期合计", "Current cache · not lifetime usage")
        }
        return "\(range) · \(calendar.timeZone.identifier)"
    }

    /// 总额与三桶都用真实整数，API 等效价与计价覆盖并列，缺价保留已知 Token。
    private func overview(_ totals: PowertoolsUsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
                metric(antigravityText("API 等效估算 (USD)", "API equivalent (USD)"), value: PowertoolsDisplay.cost(totals), emphasized: true)
                metric(antigravityText("总 Token", "Total tokens"), value: PowertoolsDisplay.number(totals.totalTokens), emphasized: true)
            }
            HStack(spacing: 12) {
                metric(antigravityText("未缓存输入", "New input"), value: PowertoolsDisplay.number(totals.newInputTokens))
                metric(antigravityText("缓存输入", "Cached input"), value: PowertoolsDisplay.number(totals.cachedInputTokens))
                metric(antigravityText("输出", "Output"), value: PowertoolsDisplay.number(totals.outputTokens))
            }
            HStack(spacing: 12) {
                metric(antigravityText("记录数", "Records"), value: PowertoolsDisplay.number(Int64(totals.recordCount)))
                metric(antigravityText("已计价记录", "Priced records"), value: "\(totals.pricedRecordCount)/\(totals.recordCount)")
                metric(antigravityText("缓存命中率", "Cache hit rate"), value: PowertoolsDisplay.hitRate(totals))
            }
            if totals.pricedRecordCount < totals.recordCount {
                Label(antigravityText("仅估算已计价记录；未计价记录不按 $0 处理。", "Only priced records are estimated; unpriced records are not treated as $0."), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 多列指标共用等宽和数字字体；窄弹窗可缩放，悬停和无障碍仍可取得完整数值。
    private func metric(_ title: String, value: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .font((emphasized ? (compact ? Font.title3 : .title2) : .caption).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(title): \(value)")
        .accessibilityElement(children: .combine)
    }

    /// 弹窗只展示靠前模型，设置页展示全量；短期趋势始终是当前日及前六个本地日历日。
    private func detailContent(snapshot: PowertoolsUsageSnapshot, summary: PowertoolsUsagePeriodSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(antigravityText("所选区间 · 按模型", "Selected period · by model"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if summary.models.isEmpty {
                Text(antigravityText("该时段暂无模型记录。", "No model records for this period."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                if compact {
                    let models = Array(summary.models.prefix(5))
                    // 弹窗隐藏测量副本必须展开全部五行，不能依赖尚未进入视口的惰性布局。
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(models) { model in modelRow(model) }
                    }
                    if models.count < summary.models.count {
                        let remaining = summary.models.count - models.count
                        Text(antigravityText("另有 \(remaining) 个模型，在设置 Antigravity 页查看。", "\(remaining) more models in Antigravity Settings."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.models) { model in modelRow(model) }
                    }
                }
            }
            Divider()
            dailyTrend(snapshot)
        }
    }

    /// 模型金额沿用相同计价覆盖；设置页另列该模型三桶、记录数与缓存命中率。
    private func modelRow(_ model: PowertoolsUsageModel) -> some View {
        let title = model.id == "unknown" ? antigravityText("未知模型", "Unknown model") : model.id
        let totals = model.totals
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .help(title)
                Spacer(minLength: 4)
                Text("\(PowertoolsDisplay.number(totals.totalTokens)) Token")
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(PowertoolsDisplay.cost(totals))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            if !compact {
                Text(antigravityText(
                    "未缓存 \(PowertoolsDisplay.number(totals.newInputTokens)) · 缓存 \(PowertoolsDisplay.number(totals.cachedInputTokens)) · 输出 \(PowertoolsDisplay.number(totals.outputTokens))",
                    "New \(PowertoolsDisplay.number(totals.newInputTokens)) · Cached \(PowertoolsDisplay.number(totals.cachedInputTokens)) · Output \(PowertoolsDisplay.number(totals.outputTokens))"
                ))
                .foregroundStyle(.secondary)
                Text(antigravityText("已计价记录 \(totals.pricedRecordCount)/\(totals.recordCount) · 命中率 \(PowertoolsDisplay.hitRate(totals))", "Priced records \(totals.pricedRecordCount)/\(totals.recordCount) · Hit rate \(PowertoolsDisplay.hitRate(totals))"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }

    /// 不存在的日期显式标记无记录；小比例条只比较真实 Token，零值记录和缺失日从视觉上区分。
    private func dailyTrend(_ snapshot: PowertoolsUsageSnapshot) -> some View {
        let summary = snapshot.summary(for: .sevenDays, now: now)
        let today = snapshot.calendar.startOfDay(for: now)
        let dates = (0..<7).compactMap { snapshot.calendar.date(byAdding: .day, value: $0 - 6, to: today) }
        let maximum = max(Int64(1), summary.days.map(\.totals.totalTokens).max() ?? 0)
        return VStack(alignment: .leading, spacing: 5) {
            Text(antigravityText("近 7 天每日趋势 · Token / USD", "Last 7 calendar days · Token / USD"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(dates, id: \.self) { date in
                HStack(spacing: 6) {
                    Text(PowertoolsDisplay.date(date, calendar: snapshot.calendar, includesTime: false))
                        .foregroundStyle(.secondary)
                    if let day = summary.days.first(where: { $0.date == date }) {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: geometry.size.width * CGFloat(day.totals.totalTokens) / CGFloat(maximum))
                        }
                        .frame(height: 4)
                        .accessibilityHidden(true)
                        Text(PowertoolsDisplay.number(day.totals.totalTokens))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(PowertoolsDisplay.cost(day.totals))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    } else {
                        Spacer(minLength: 4)
                        Text(antigravityText("无记录", "No records"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 来源有效性、检查时刻、原事件覆盖及单价目录时间始终独立展示；文件长期不动不删除历史。
    private func sourceDetails(_ snapshot: PowertoolsUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            metadataRow(antigravityText("文件更新", "File modified"),
                        PowertoolsDisplay.date(snapshot.sourceModifiedAt, calendar: snapshot.calendar))
            metadataRow(antigravityText("最近本地检查", "Last local check"),
                        PowertoolsDisplay.date(store.lastCheckedAt, calendar: snapshot.calendar))
            metadataRow(antigravityText("记录起止", "Record coverage"),
                        "\(PowertoolsDisplay.date(snapshot.observedStart, calendar: snapshot.calendar)) – \(PowertoolsDisplay.date(snapshot.observedEnd, calendar: snapshot.calendar))")
            metadataRow(antigravityText("价格目录检查", "Price catalog check"),
                        PowertoolsDisplay.date(snapshot.pricingCheckedAt, calendar: snapshot.calendar))

            if snapshot.isStale(now: now) {
                Label(antigravityText("文件可能滞后或插件处于空闲，仍显示已记录历史。", "File may be stale or the plugin idle; recorded history is still shown."), systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if snapshot.sourceRecordCount == 0 {
                Text(antigravityText("当前缓存为空。", "The current cache is empty."))
            } else if snapshot.observedStart == nil {
                Label(antigravityText("当前缓存无可验证记录。", "The current cache has no verifiable records."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if snapshot.rejectedRecordCount > 0 || snapshot.conflictingIDCount > 0 {
                Label(antigravityText(
                    "部分记录不可计：排除 \(snapshot.rejectedRecordCount) 条无效记录、\(snapshot.conflictingIDCount) 组冲突 ID。",
                    "Partial data: excluded \(snapshot.rejectedRecordCount) invalid records and \(snapshot.conflictingIDCount) conflicting ID groups."
                ), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            }
            if snapshot.duplicateRecordCount > 0 {
                Text(antigravityText("相同计量事件已去重（\(snapshot.duplicateRecordCount) 条）。", "Deduplicated \(snapshot.duplicateRecordCount) identical metered records."))
            }
            if let pricingIssue = snapshot.pricingIssue {
                Label(PowertoolsDisplay.notice(pricingIssue), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text(antigravityText("插件约保留 90 天、最多 2 万条；按缓存公开单价估算，不含未记录计费项，不是实际订阅扣费。", "Plugin retains about 90 days and up to 20k records. Estimates use cached list prices, exclude unrecorded charges, and are not actual billing."))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 时间值较长可换行，避免窄弹窗截掉日期；标签与值都归属当前本机来源。
    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
