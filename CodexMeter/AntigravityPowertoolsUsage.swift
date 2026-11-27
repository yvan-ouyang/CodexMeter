// 只读消费 Agy Powertools 已整理的桌面计量与公开单价缓存；不扫描会话、不访问认证或网络。
import Foundation
import Darwin

/// 本机日历统计区间；保留记录表示当前第三方缓存中的范围，不是账户生命周期。
enum PowertoolsUsagePeriod: String, CaseIterable, Identifiable {
    case today, sevenDays, month, retained
    var id: String { return rawValue }

    /// 为弹窗与设置页提供同一组紧凑区间标题。
    var title: String {
        switch self {
        case .today: return "今日"
        case .sevenDays: return "近 7 天"
        case .month: return "本月"
        case .retained: return "保留记录"
        }
    }
}

/// 已验证记录的三桶统计与已计价部分；缺少价格不是零费用，cache 已含在总输入中。
struct PowertoolsUsageTotals: Equatable {
    private(set) var recordCount = 0
    private(set) var newInputTokens: Int64 = 0
    private(set) var cachedInputTokens: Int64 = 0
    private(set) var outputTokens: Int64 = 0
    private(set) var pricedRecordCount = 0
    private var pricedCostUSD: Double = 0

    var totalInputTokens: Int64 { return newInputTokens + cachedInputTokens }
    var totalTokens: Int64 { return totalInputTokens + outputTokens }
    var estimatedCostUSD: Double? { return pricedRecordCount > 0 ? pricedCostUSD : nil }
    var cacheHitFraction: Double? {
        return totalInputTokens > 0 ? Double(cachedInputTokens) / Double(totalInputTokens) : nil
    }

    /// 在输入端保证条数和每桶数值上限，所有日、模型及期间累加均不会溢出 Int64。
    fileprivate mutating func record(input: Int64, cache: Int64, output: Int64, cost: Double?) {
        recordCount += 1
        newInputTokens += input; cachedInputTokens += cache; outputTokens += output
        if let cost = cost { pricedRecordCount += 1; pricedCostUSD += cost }
    }

    /// 各日的模型集合不相交；合并时保留已计条数与金额，不能把未知价补成已计零价。
    fileprivate mutating func merge(_ other: PowertoolsUsageTotals) {
        recordCount += other.recordCount
        newInputTokens += other.newInputTokens; cachedInputTokens += other.cachedInputTokens; outputTokens += other.outputTokens
        pricedRecordCount += other.pricedRecordCount; pricedCostUSD += other.pricedCostUSD
    }
}

/// 以标准化模型名为键的显示汇总；未知模型专用键不参与价格猜测。
struct PowertoolsUsageModel: Equatable, Identifiable {
    let id: String
    let totals: PowertoolsUsageTotals
}

/// 单个本地日历日的已记录消耗；不存在的日期不创建虚假事件。
struct PowertoolsUsageDay: Equatable, Identifiable {
    let date: Date
    let totals: PowertoolsUsageTotals
    var id: Date { return date }
}

/// 同一次源读取的阶段性展示，所有模型、日期、金额可以独立对账。
struct PowertoolsUsagePeriodSummary: Equatable {
    let totals: PowertoolsUsageTotals
    let models: [PowertoolsUsageModel]
    let days: [PowertoolsUsageDay]
}

/// 源读取结果只携带模型/日汇总及覆盖诊断；请求ID与所有非计量字段不会跨越读取边界。
struct PowertoolsUsageSnapshot: Equatable {
    let sourceModifiedAt: Date
    let readAt: Date
    let pricingCheckedAt: Date?
    let pricingIssue: String?
    let observedStart: Date?
    let observedEnd: Date?
    let sourceRecordCount: Int
    let duplicateRecordCount: Int
    let rejectedRecordCount: Int
    let conflictingIDCount: Int
    let calendar: Calendar
    fileprivate let dailyModels: [Date: [String: PowertoolsUsageTotals]]

    /// 仅表示当前缓存是否可能未更新；历史统计保留，但不能声称是账户实时数据。
    func isStale(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(sourceModifiedAt)
        return !age.isFinite || age < 0 || age >= 300
    }

    /// 每次展示按同一读取的本机日历选择期间；手动模式跨午夜也不会把昨日标成今日。
    func summary(for period: PowertoolsUsagePeriod, now: Date = Date()) -> PowertoolsUsagePeriodSummary {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let start: Date?
        switch period {
        case .today: start = today
        case .sevenDays: start = calendar.date(byAdding: .day, value: -6, to: today)
        case .month: start = calendar.dateInterval(of: .month, for: today)?.start
        case .retained: start = nil
        }
        var overall = PowertoolsUsageTotals(), byModel: [String: PowertoolsUsageTotals] = [:]
        var days: [PowertoolsUsageDay] = []
        for day in dailyModels.keys.sorted() {
            if let start = start, day < start { continue }
            // 保留记录仅表示实际已有数据；有限日历期间不能提前计入明天。
            if period != .retained && day >= tomorrow { continue }
            var total = PowertoolsUsageTotals()
            for (model, values) in dailyModels[day] ?? [:] {
                total.merge(values)
                byModel[model, default: PowertoolsUsageTotals()].merge(values)
            }
            overall.merge(total)
            days.append(PowertoolsUsageDay(date: day, totals: total))
        }
        let models = byModel.map { PowertoolsUsageModel(id: $0.key, totals: $0.value) }.sorted {
            if $0.totals.totalTokens == $1.totals.totalTokens { return $0.id < $1.id }
            return $0.totals.totalTokens > $1.totals.totalTokens
        }
        return PowertoolsUsagePeriodSummary(totals: overall, models: models, days: days)
    }
}

/// 只暴露有限诊断原因，不把真实文件内容、路径或三方错误正文传给用户或日志。
enum PowertoolsUsageReadError: LocalizedError {
    case missing, inaccessible, tooLarge, invalidFormat, changedDuringRead
    var errorDescription: String? {
        switch self {
        case .missing: return "等待 Powertools 生成本机用量记录。"
        case .inaccessible: return "Powertools 本机文件不可读或类型不安全。"
        case .tooLarge: return "Powertools 本机统计超过读取上限。"
        case .invalidFormat: return "Powertools 统计格式无效，等待有效记录。"
        case .changedDuringRead: return "Powertools 正在更新记录，请稍后刷新。"
        }
    }
}

/// 有界只读打开固定缓存；绝不追随异常链接、访问同目录其他文件或写入源数据。
struct PowertoolsUsageReader {
    static let maximumUsageBytes = 16 * 1024 * 1024
    static let maximumPriceBytes = 2 * 1024 * 1024
    static let maximumRecords = 25_000
    // 单请求远超实际上下文的安全上限；即使 25,000 条三桶均达上限，总和也小于 Int64.max。
    static let maximumTokensPerBucket: Int64 = 1_000_000_000_000
    let directoryURL: URL

    /// 仅注入测试目录；正常路径固定为桌面 Powertools 缓存，不使用环境变量或插件默认的 CLI 合并范围。
    init(directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/plugin_data/agy-powertools")) {
        self.directoryURL = directoryURL
    }

    /// 同一次读取汇总两份缓存；价格独立失败时仍保留真实 Token 与记录覆盖。
    func load(now: Date = Date(), calendar: Calendar = .current) throws -> PowertoolsUsageSnapshot {
        let usage = try readFile(name: "usage-history-cache.json", limit: Self.maximumUsageBytes)
        guard let raw = try? JSONDecoder().decode([RawEvent].self, from: usage.data) else {
            throw PowertoolsUsageReadError.invalidFormat
        }
        guard raw.count <= Self.maximumRecords else { throw PowertoolsUsageReadError.tooLarge }
        let pricing: PricingCatalog
        var pricingIssue: String?
        do {
            let file = try readFile(name: "pricing.json", limit: Self.maximumPriceBytes)
            pricing = try PricingCatalog(data: file.data)
            if pricing.rates.isEmpty { pricingIssue = "未获得有效模型价格。" }
            else if pricing.invalidCount > 0 { pricingIssue = "部分模型价格缺失或冲突。" }
        } catch {
            pricing = PricingCatalog()
            pricingIssue = "未获得有效模型价格。"
        }

        var facts: [String: MeteredEvent] = [:], conflicts = Set<String>(), incompleteIDs = Set<String>()
        var duplicateCount = 0, rejectedCount = 0
        let latest = now.timeIntervalSince1970 * 1000
        for record in raw {
            guard let identity = record.id, !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  identity.utf8.count <= 1024,
                  !identity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                rejectedCount += 1; continue
            }
            guard let timestamp = record.timestampMs, timestamp.isFinite, timestamp > 0,
                  timestamp <= latest, timestamp < 253_402_300_800_000,
                  let input = record.inputTokens, let cache = record.cacheReadTokens, let output = record.outputTokens,
                  [input, cache, output].allSatisfy({ $0 >= 0 && $0 <= Self.maximumTokensPerBucket }) else {
                // 有 ID 的坏行同样影响去重证明；若另有有效同 ID 行，整组不能作为可靠事实。
                if facts[identity] != nil || incompleteIDs.contains(identity) { conflicts.insert(identity) }
                incompleteIDs.insert(identity)
                rejectedCount += 1; continue
            }
            let normalizedModel = Self.modelKey(record.model)
            let model = normalizedModel ?? "unknown"
            // 未识别模型的统一展示名不是请求身份。有限原始标签只用于本轮内存判重，不向界面传播。
            let unknownLabel = record.model.flatMap { $0.utf8.count <= 128 ? $0 : nil }
            let fact = MeteredEvent(timestampMs: timestamp, model: model,
                                    identityModel: normalizedModel ?? unknownLabel, input: input, cache: cache, output: output)
            if incompleteIDs.contains(identity) { conflicts.insert(identity) }
            if let existing = facts[identity] {
                if existing.identityModel != nil && fact.identityModel != nil && existing == fact { duplicateCount += 1 }
                else { conflicts.insert(identity) }
            } else { facts[identity] = fact }
        }
        var daily: [Date: [String: PowertoolsUsageTotals]] = [:]
        var oldest: Date?, newest: Date?
        for (identity, fact) in facts where !conflicts.contains(identity) {
            let date = Date(timeIntervalSince1970: fact.timestampMs / 1000)
            let day = calendar.startOfDay(for: date)
            let cost = pricing.cost(for: fact, date: date)
            daily[day, default: [:]][fact.model, default: PowertoolsUsageTotals()].record(input: fact.input, cache: fact.cache, output: fact.output, cost: cost)
            oldest = oldest.map { min($0, date) } ?? date
            newest = newest.map { max($0, date) } ?? date
        }
        return PowertoolsUsageSnapshot(sourceModifiedAt: usage.modifiedAt, readAt: now, pricingCheckedAt: pricing.checkedAt,
            pricingIssue: pricingIssue, observedStart: oldest, observedEnd: newest, sourceRecordCount: raw.count,
            duplicateRecordCount: duplicateCount, rejectedRecordCount: rejectedCount, conflictingIDCount: conflicts.count,
            calendar: calendar, dailyModels: daily)
    }

    /// 仅标准化公开计量中可识别的厂商模型标识和明确档位；未知路由不套默认模型价格。
    fileprivate static func modelKey(_ raw: String?) -> String? {
        guard let raw = raw, raw.utf8.count <= 128 else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed.replacingOccurrences(of: #"\s*\((?:low|medium|high|xhigh|max|minimal|none|ultra)\)\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]).lowercased()
        value = value.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        if value.hasPrefix("claude-") {
            value = value.replacingOccurrences(of: #"(?<=\d)\.(?=\d)"#, with: "-", options: .regularExpression)
        }
        guard value.range(of: #"\A(?:gemini-[a-z0-9.-]+|claude-[a-z0-9.-]+|gpt-[a-z0-9.-]+)\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// 打开 app 拥有的普通目录和普通文件，文件上限在读前及读中均检查。
    private func readFile(name: String, limit: Int) throws -> (data: Data, modifiedAt: Date) {
        guard name == "usage-history-cache.json" || name == "pricing.json" else { throw PowertoolsUsageReadError.inaccessible }
        let directory = directoryURL.standardizedFileURL
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw PowertoolsUsageReadError.inaccessible }
        var components = Array(directory.pathComponents.dropFirst())
        // macOS 固定的系统目录别名可直接使用规范位置；任何应用私有祖先都不得跟随链接。
        if components.first == "tmp" || components.first == "var" { components.insert("private", at: 0) }
        var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw PowertoolsUsageReadError.inaccessible }
        defer { _ = close(directoryFD) }
        // 逐级打开目录描述符，固定已检查的父目录；不以事前 lstat 后重新拼路径的方式跨越链接。
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw PowertoolsUsageReadError.inaccessible
            }
            let next = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw errno == ENOENT ? PowertoolsUsageReadError.missing : PowertoolsUsageReadError.inaccessible }
            _ = close(directoryFD)
            directoryFD = next
        }
        let fd = openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? PowertoolsUsageReadError.missing : PowertoolsUsageReadError.inaccessible }
        defer { _ = close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_size >= 0 else {
            throw PowertoolsUsageReadError.inaccessible
        }
        guard before.st_size <= Int64(limit) else { throw PowertoolsUsageReadError.tooLarge }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw PowertoolsUsageReadError.inaccessible
            }
            if count == 0 { break }
            guard bytes.count + count <= limit else { throw PowertoolsUsageReadError.tooLarge }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == before.st_size, bytes.count == Int(after.st_size),
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw PowertoolsUsageReadError.changedDuringRead
        }
        let modifiedAt = Date(timeIntervalSince1970: Double(after.st_mtimespec.tv_sec) + Double(after.st_mtimespec.tv_nsec) / 1_000_000_000)
        return (bytes, modifiedAt)
    }
}

/// JSON 解码仅列计量字段；坏行可独立排除，其他字段即使存在也不读取到业务对象。
private struct RawEvent: Decodable {
    let id: String?
    let timestampMs: Double?
    let model: String?
    let inputTokens: Int64?
    let cacheReadTokens: Int64?
    let outputTokens: Int64?
    private enum CodingKeys: String, CodingKey { case id, timestampMs, model, inputTokens, cacheReadTokens, outputTokens }

    /// 每个白名单字段独立解码，保持缺失/错误与实际0的差异。
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        id = c.flatMap { try? $0.decode(String.self, forKey: .id) }
        timestampMs = c.flatMap { try? $0.decode(Double.self, forKey: .timestampMs) }
        model = c.flatMap { try? $0.decode(String.self, forKey: .model) }
        inputTokens = c.flatMap { try? $0.decode(Int64.self, forKey: .inputTokens) }
        cacheReadTokens = c.flatMap { try? $0.decode(Int64.self, forKey: .cacheReadTokens) }
        outputTokens = c.flatMap { try? $0.decode(Int64.self, forKey: .outputTokens) }
    }
}

/// 仅一次读取中的短期去重事实，比较时间与三桶及模型，不将身份交给显示层。
private struct MeteredEvent: Equatable {
    let timestampMs: Double
    let model: String
    let identityModel: String?
    let input: Int64
    let cache: Int64
    let output: Int64
}

/// 同一已读价目录的准确三桶单价和明确生效日期；不使用目录中的网址进行网络访问。
private struct PricingCatalog {
    struct Prices: Decodable, Equatable {
        let input: Double
        let cache: Double
        let output: Double
        var valid: Bool { return [input, cache, output].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 10_000 } }
    }
    struct Rate: Equatable {
        let current: Prices
        let changeAt: Date?
        let next: Prices?
    }
    struct RawCatalog: Decodable {
        let checkedAt: String?
        let rates: [RawRate]
        private enum CodingKeys: String, CodingKey { case checkedAt, rates }
        /// 价格目录的时间无效不妨碍合法单价；根或 rates 结构无效拒绝整份。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            checkedAt = try? c.decode(String.self, forKey: .checkedAt)
            rates = try c.decode([RawRate].self, forKey: .rates)
        }
    }
    struct RawRate: Decodable {
        let model: String?
        let current: Prices?
        let hasSchedule: Bool
        let until: String?
        let next: Prices?
        private enum CodingKeys: String, CodingKey { case model, until, next }
        /// 错误或不完整的明确价格变更不能误落回旧价；其他合法模型保持可用。
        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            model = c.flatMap { try? $0.decode(String.self, forKey: .model) }
            current = c == nil ? nil : (try? Prices(from: decoder))
            hasSchedule = c.map { $0.contains(.until) || $0.contains(.next) } ?? false
            until = c.flatMap { try? $0.decode(String.self, forKey: .until) }
            next = c.flatMap { try? $0.decode(Prices.self, forKey: .next) }
        }
    }
    var rates: [String: Rate] = [:]
    var checkedAt: Date?
    var invalidCount = 0

    /// 价格文件缺失时使用空目录，绝不把实际 Token 读数降级为无用量。
    init() {}

    /// 精确规范化、校验和去除冲突价格；同一目录不混入原 Codex 内置价。
    init(data: Data) throws {
        let raw = try JSONDecoder().decode(RawCatalog.self, from: data)
        guard raw.rates.count <= 5000 else { throw PowertoolsUsageReadError.tooLarge }
        if let text = raw.checkedAt, text.utf8.count <= 128 {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            checkedAt = formatter.date(from: text)
            if checkedAt == nil { formatter.formatOptions = [.withInternetDateTime]; checkedAt = formatter.date(from: text) }
        }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = TimeZone(secondsFromGMT: 0); day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
        var invalidModels = Set<String>()
        for entry in raw.rates {
            guard let model = PowertoolsUsageReader.modelKey(entry.model) else { invalidCount += 1; continue }
            guard let prices = entry.current, prices.valid else { invalidCount += 1; invalidModels.insert(model); continue }
            let rate: Rate
            if entry.hasSchedule {
                guard let text = entry.until, text.utf8.count == 10, let date = day.date(from: text), day.string(from: date) == text,
                      let next = entry.next, next.valid else { invalidCount += 1; invalidModels.insert(model); continue }
                rate = Rate(current: prices, changeAt: date, next: next)
            } else { rate = Rate(current: prices, changeAt: nil, next: nil) }
            if let previous = rates[model], previous != rate { invalidModels.insert(model); invalidCount += 1 }
            else { rates[model] = rate }
        }
        for model in invalidModels { rates.removeValue(forKey: model) }
    }

    /// 按请求 UTC 时刻选择事件价格；输出已含思考 token，不再次计费，未知模型返回 nil。
    func cost(for event: MeteredEvent, date: Date) -> Double? {
        guard let rate = rates[event.model] else { return nil }
        let prices: Prices
        if let change = rate.changeAt, date >= change, let next = rate.next { prices = next }
        else { prices = rate.current }
        let value = (Double(event.input) * prices.input + Double(event.cache) * prices.cache + Double(event.output) * prices.output) / 1_000_000
        return value.isFinite && value >= 0 ? value : nil
    }
}

#if swift(>=5.5)
extension PowertoolsUsagePeriod: Sendable {}
extension PowertoolsUsageTotals: Sendable {}
extension PowertoolsUsageModel: Sendable {}
extension PowertoolsUsageDay: Sendable {}
extension PowertoolsUsagePeriodSummary: Sendable {}
extension PowertoolsUsageSnapshot: Sendable {}
extension PowertoolsUsageReader: Sendable {}
extension PowertoolsUsageReadError: Sendable {}
#endif
