// 将独立的官方 CLI 本地观测适配到已有 Antigravity 卡片；不主动启动 CLI 或访问供应商网络。
import Foundation
import CodexMeterShared

/// CLI 数据缺失、读取错误的展示语义与旧网络客户端隔离。
struct AntigravityStatuslineUsageClient: GeminiModelsUsageFetching, Sendable {
    let store: AntigravityStatuslineStore

    /// 注入真实快照位置，测试不读取用户个人文件。
    init(store: AntigravityStatuslineStore = AntigravityStatuslineStore()) { self.store = store }

    /// 遵循现有异步供应商协议，实际只读本地文件。
    func fetchGeminiModels() async throws -> GeminiModelsSnapshot { try loadSnapshot() }

    /// 把当前接受的单份帧映射到现有模型组；无有效观测明确等待，不回退其他来源。
    func loadSnapshot() throws -> GeminiModelsSnapshot {
        guard let frame = try store.load(), !frame.buckets.isEmpty else { throw WaitingForStatusline() }
        let groups: [(String, String, [String])] = [
            ("gemini-models", "Gemini Models", ["gemini-5h", "gemini-weekly"]),
            ("claude-gpt-models", "Claude and GPT models", ["3p-5h", "3p-weekly"])
        ]
        let mapped = groups.compactMap { group -> GeminiQuotaGroup? in
            let windows = group.2.compactMap { id -> GeminiQuotaWindow? in
                guard let bucket = frame.buckets.first(where: { $0.id == id }) else { return nil }
                return GeminiQuotaWindow(bucketId: id,
                    title: id.hasSuffix("-5h") ? "Five Hour Limit Remaining" : "Weekly Limit Remaining",
                    remainingFraction: bucket.remainingFraction, resetsAt: bucket.resetsAt, disabled: bucket.disabled)
            }
            guard !windows.isEmpty else { return nil }
            return GeminiQuotaGroup(id: group.0, title: group.1, windows: windows)
        }
        return GeminiModelsSnapshot(fetchedAt: frame.capturedAt, source: .antigravityCLIStatusline,
            accountEmail: frame.accountEmail, planName: frame.planName, groups: mapped)
    }

    /// 初始化或账号切换时等待下一份有效回调，避免显示无来源的旧值。
    struct WaitingForStatusline: LocalizedError {
        var errorDescription: String? { AppLocalization.string("等待官方 CLI Statusline 额度快照。请保持 CLI 运行并正常刷新额度。") }
    }
}

/// CLI 来源的显示时间由真实捕获时间计算；本地重读和 UI 计时不得伪造观察时间或额度重置。
enum AntigravityStatuslinePresentation {
    static let staleAfter: TimeInterval = 120

    /// 时钟回退或观测超过两分钟均不能声称是新鲜数据。
    static func isStale(_ snapshot: GeminiModelsSnapshot, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        return !age.isFinite || age < 0 || age >= staleAfter
    }

    /// 已过期或已到达边界的窗口移除计算用 reset，只保留真实剩余量及等待更新提示；输入快照不变。
    static func project(_ snapshot: GeminiModelsSnapshot, now: Date = Date()) -> GeminiModelsSnapshot {
        guard snapshot.source == .antigravityCLIStatusline else { return snapshot }
        let stale = isStale(snapshot, now: now)
        let groups = snapshot.groups.map { group in
            GeminiQuotaGroup(id: group.id, title: group.title, description: group.description, windows: group.windows.map { window in
                let expired = window.resetsAt.map { $0 <= now } ?? false
                let reset = !stale && !expired && !window.disabled ? window.resetsAt : nil
                return GeminiQuotaWindow(bucketId: window.bucketId, title: window.title,
                    remainingFraction: window.remainingFraction, resetsAt: reset,
                    resetDescription: (stale || expired) && window.resetsAt != nil && !window.disabled
                        ? "等待 CLI 更新" : window.resetDescription, disabled: window.disabled)
            })
        }
        return GeminiModelsSnapshot(fetchedAt: snapshot.fetchedAt, source: snapshot.source,
            accountEmail: snapshot.accountEmail, planName: snapshot.planName, groups: groups)
    }

    /// 无比例的窗口也可能有独立有效的重置时间；只显示未来时间，不构造虚假的 RateLimitWindow。
    static func countdown(_ window: GeminiQuotaWindow, formatter: UsageFormatter, now: Date = Date()) -> String? {
        guard !window.disabled, let reset = window.resetsAt, reset > now else { return nil }
        let seconds = Int(ceil(reset.timeIntervalSince(now)))
        let duration = formatter.compactDuration(seconds: seconds)
        return AppLocalization.usesEnglish() ? "in \(duration)" : "\(duration)后"
    }

    /// 菜单栏与额度卡用同一明确来源/日期文案，提示该时间不是服务端实时查询。
    static func summary(_ snapshot: GeminiModelsSnapshot, now: Date = Date()) -> String {
        let time = DateFormatter()
        time.dateStyle = .short
        time.timeStyle = .short
        let observed = AppLocalization.string("最近采集") + " " + time.string(from: snapshot.fetchedAt)
        return "CLI Statusline · \(observed) · " + AppLocalization.string(isStale(snapshot, now: now) ? "快照可能已过期" : "仅随 CLI 状态更新")
    }
}

extension Notification.Name {
    /// CLI 独立展示变化，object 只传当前已投影快照；设置页无需再读或改 Codex 共享缓存。
    static let antigravityCLIStatuslineDidChange = Notification.Name("CodexMeter.antigravityCLIStatuslineDidChange")
    /// 设置窗口或其他显式本地展示入口请求同一 ViewModel 读取 CLI 快照。
    static let antigravityCLIStatuslineRefreshRequested = Notification.Name("CodexMeter.antigravityCLIStatuslineRefreshRequested")
}
