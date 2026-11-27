// 新来源的映射、用户偏好、独立发布与回归保护；合成输入不依赖真实账号或 Google 网络。
import Foundation
import XCTest
@testable import CodexMeterShared

@MainActor
final class AntigravityStatuslineTests: XCTestCase {
    /// 旧用户未设置来源时继续旧路径；错误来源不会暗中落回网络探测。
    func testSourceSelectionKeepsLegacyDefaultAndRejectsUnknownValue() throws {
        let name = "AntigravityStatuslineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: GeminiModelsPreferenceKeys.isEnabled)
        XCTAssertTrue(GeminiModelsSettings(defaults: defaults).usesLegacySource)
        defaults.set(GeminiModelsDataSource.cliStatusline.rawValue, forKey: GeminiModelsPreferenceKeys.dataSource)
        XCTAssertTrue(GeminiModelsSettings(defaults: defaults).usesCLIStatusline)
        defaults.set("unknown-source", forKey: GeminiModelsPreferenceKeys.dataSource)
        XCTAssertFalse(GeminiModelsSettings(defaults: defaults).usesLegacySource)
        XCTAssertFalse(GeminiModelsSettings(defaults: defaults).usesCLIStatusline)
    }

    /// 四个真实桶使用同一来源文件投影，陈旧或越过重置边界时不提供误导预测。
    func testProjectionUsesFourBucketsAndRetainsCaptureTimeWhenStale() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let t = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-26T09:00:00Z"))
        let store = AntigravityStatuslineStore(snapshotURL: temp.appendingPathComponent("cli-statusline-v1.json"))
        try store.receive(Self.payload(), at: t)
        let client = AntigravityStatuslineUsageClient(store: store)
        let raw = try client.loadSnapshot()
        XCTAssertEqual(raw.source, .antigravityCLIStatusline)
        XCTAssertEqual(raw.fetchedAt, t)
        XCTAssertEqual(raw.groups.map(\.id), ["gemini-models", "claude-gpt-models"])
        XCTAssertEqual(raw.groups.flatMap(\.windows).map(\.remainingPercent), [72, 96, 100, 50])
        XCTAssertNil(raw.groups[1].windows[0].resetsAt)
        // 五分钟本地检查对应新的 CLI 陈旧边界；检查时间不是观测时间。
        XCTAssertFalse(AntigravityStatuslinePresentation.isStale(raw, now: t.addingTimeInterval(299)))
        let stale = AntigravityStatuslinePresentation.project(raw, now: t.addingTimeInterval(300))
        XCTAssertTrue(AntigravityStatuslinePresentation.isStale(raw, now: t.addingTimeInterval(300)))
        XCTAssertTrue(AntigravityStatuslinePresentation.isStale(raw, now: t.addingTimeInterval(-1)))
        XCTAssertEqual(stale.fetchedAt, t)
        XCTAssertEqual(stale.groups.flatMap(\.windows).map(\.remainingPercent), [72, 96, 100, 50])
        XCTAssertTrue(stale.groups.flatMap(\.windows).allSatisfy { $0.resetsAt == nil })
        XCTAssertEqual(try client.loadSnapshot().fetchedAt, t)
    }

    /// 菜单栏继续解析原布局项目，CLI 指标带来源标识且错误来源不能串入。
    func testMenuBarUsesOnlySelectedSourceAndMarksStaleQuota() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = AntigravityStatuslineStore(snapshotURL: temp.appendingPathComponent("cli-statusline-v1.json"))
        try store.receive(Self.payload(), at: Date().addingTimeInterval(-301))
        let cli = try AntigravityStatuslineUsageClient(store: store).loadSnapshot()
        let settings = GeminiModelsSettings(isEnabled: true, showsInMenuBar: true, dataSource: .cliStatusline)
        let line = try XCTUnwrap(StatusLineDisplay.layoutGeminiLine(for: .geminiPrimary, settings: MenuBarDisplaySettings(), geminiSettings: settings, snapshot: cli))
        XCTAssertEqual(line.value, "72%")
        XCTAssertTrue(line.label.contains("CLI*"))
        XCTAssertNil(StatusLineDisplay.layoutGeminiLine(for: .geminiResetCountdown, settings: MenuBarDisplaySettings(), geminiSettings: settings, snapshot: cli))
        XCTAssertNil(StatusLineDisplay.layoutGeminiLine(for: .geminiDepletionETA, settings: MenuBarDisplaySettings(), geminiSettings: settings, snapshot: cli))
        let bar = try XCTUnwrap(StatusLineDisplay.layoutGeminiUsageBar(for: .geminiUsageBar, geminiSettings: settings, snapshot: cli))
        XCTAssertEqual(bar.statuslineBadge, "C!")
        XCTAssertNotNil(bar.statuslineDetail)
        let oldSettings = GeminiModelsSettings(isEnabled: true, showsInMenuBar: true)
        XCTAssertNil(StatusLineDisplay.layoutGeminiLine(for: .geminiPrimary, settings: MenuBarDisplaySettings(), geminiSettings: oldSettings, snapshot: cli))
    }

    /// 即使主 Codex 请求失败也能获得 CLI 额度；显式 CLI 模式不会调用旧客户端或污染共享缓存。
    func testCLIRefreshSurvivesCodexFailureWithoutLegacyRequestOrSharedCLIData() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let local = AntigravityStatuslineStore(snapshotURL: temp.appendingPathComponent("cli").appendingPathComponent("cli-statusline-v1.json"))
        try local.receive(Self.payload(), at: Date())
        let store = UsageSnapshotStore(appGroupIdentifier: "", fallbackDirectory: temp.appendingPathComponent("codex"))
        let limits = Self.codexLimits()
        let legacy = GeminiModelsSnapshot(fetchedAt: Date(), source: .antigravityLocal, groups: [])
        try store.save(UsageSnapshot(fetchedAt: Date(), rateLimits: limits, geminiModels: legacy))
        let counter = StatuslineTestCounter()
        let vm = UsageViewModel(client: StatuslineFailingCodex(), store: store, reloadWidgetTimelines: {},
            refreshCadenceProvider: { .manual }, geminiClient: StatuslineCountingLegacy(counter: counter, snapshot: legacy),
            statuslineClient: AntigravityStatuslineUsageClient(store: local),
            geminiSettingsProvider: { GeminiModelsSettings(isEnabled: true, dataSource: .cliStatusline) },
            localCodexUsageLoader: { nil })
        XCTAssertNil(vm.geminiSnapshot)
        await vm.refresh()
        XCTAssertEqual(vm.geminiSnapshot?.source, .antigravityCLIStatusline)
        XCTAssertEqual(vm.geminiSnapshot?.groups.first?.windows.first?.remainingPercent, 72)
        let count = await counter.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try store.load()?.rateLimits, limits)
        XCTAssertNotEqual(try store.load()?.geminiModels?.source, .antigravityCLIStatusline)
    }

    /// 两次重叠的 CLI 检查合并；真正完成读文件的时间独立于原始四桶观测。
    func testCLIOverlappingCheckKeepsObservationAndUpdatesCheckTime() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let observation = Date().addingTimeInterval(-3600)
        let raw = GeminiModelsSnapshot(fetchedAt: observation, source: .antigravityCLIStatusline, groups: [])
        let local = StatuslineDeferredLegacy(snapshot: raw)
        let cache = UsageSnapshotStore(appGroupIdentifier: "", fallbackDirectory: temp)
        let vm = UsageViewModel(client: StatuslineFailingCodex(), store: cache, reloadWidgetTimelines: {},
            refreshCadenceProvider: { .manual }, statuslineClient: local,
            geminiSettingsProvider: { GeminiModelsSettings(isEnabled: true, dataSource: .cliStatusline) }, localCodexUsageLoader: { nil })
        let first = Task { await vm.refreshCLIStatuslineIfSelected() }
        for _ in 0..<100 {
            if await local.hasStarted { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard await local.hasStarted else { await local.release(); await first.value; return XCTFail("CLI 检查未启动") }
        XCTAssertTrue(vm.isRefreshingCLIStatusline)
        XCTAssertNil(vm.cliLastCheckedAt)
        // 同一主执行器先进入第二个检查；它等待已持有的读任务后，放行任务才能继续执行。
        let release = Task { @MainActor in await local.release() }
        await vm.refreshCLIStatuslineIfSelected()
        await release.value; await first.value
        XCTAssertEqual(vm.geminiSnapshot?.fetchedAt, observation)
        XCTAssertNotNil(vm.cliLastCheckedAt)
        XCTAssertFalse(vm.isRefreshingCLIStatusline)
        let count = await local.callCount
        XCTAssertEqual(count, 1, "重叠检查只读同一份本地事实")
        XCTAssertNil(try cache.load())
    }

    /// Codex 主请求成功且旧来源仍在途时切换，晚到数据和新 CLI 数据都不得串入旧共享缓存。
    func testLateLegacyResultCannotReplaceSelectedCLI() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let local = AntigravityStatuslineStore(snapshotURL: temp.appendingPathComponent("cli/cli-statusline-v1.json"))
        try local.receive(Self.payload(), at: Date())
        let cache = UsageSnapshotStore(appGroupIdentifier: "", fallbackDirectory: temp.appendingPathComponent("codex"))
        let old = GeminiModelsSnapshot(fetchedAt: Date(), source: .antigravityLocal, groups: [])
        let legacy = StatuslineDeferredLegacy(snapshot: old)
        let state = StatuslineSourceState()
        let vm = UsageViewModel(client: StatuslineFixedCodex(limits: Self.codexLimits()), store: cache, reloadWidgetTimelines: {},
            refreshCadenceProvider: { .manual }, geminiClient: legacy, statuslineClient: AntigravityStatuslineUsageClient(store: local),
            geminiSettingsProvider: { GeminiModelsSettings(isEnabled: state.enabled, dataSource: state.source) }, localCodexUsageLoader: { nil })
        let refresh = Task { await vm.refresh() }
        // 有界等待，不让回归测试在未触发预期调用时无限挂住 CI。
        for _ in 0..<200 {
            if await legacy.hasStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard await legacy.hasStarted else { await legacy.release(); await refresh.value; return XCTFail("旧来源未启动") }
        state.source = .cliStatusline
        await vm.refreshCLIStatuslineIfSelected()
        await legacy.release()
        await refresh.value
        XCTAssertEqual(vm.geminiSnapshot?.source, .antigravityCLIStatusline)
        XCTAssertEqual(vm.geminiSnapshot?.groups.first?.windows.first?.remainingPercent, 72)
        XCTAssertEqual(try cache.load()?.rateLimits, Self.codexLimits())
        XCTAssertNotEqual(try cache.load()?.geminiModels?.source, .antigravityCLIStatusline)
        state.enabled = false
        await vm.refresh()
        XCTAssertNil(vm.geminiSnapshot)
        XCTAssertNotNil(try local.load(), "关闭显示不删除 CLI 独立文件")
    }

    /// 已知重置时间但比例缺失能独立展示，不参与消耗节奏估算。
    func testResetOnlyWindowCanShowCountdownWithoutRemainingQuota() throws {
        let now = Date()
        let window = GeminiQuotaWindow(bucketId: "gemini-5h", title: "Five Hour Limit Remaining", remainingFraction: nil, resetsAt: now.addingTimeInterval(90))
        XCTAssertNil(window.rateLimitWindow)
        XCTAssertNotNil(AntigravityStatuslinePresentation.countdown(window, formatter: UsageFormatter(), now: now))
        XCTAssertNil(AntigravityStatuslinePresentation.countdown(window, formatter: UsageFormatter(), now: now.addingTimeInterval(91)))
    }

    /// 取消的旧读取不能再启动下一来源；使用合成取消，不访问进程或认证文件。
    func testCanceledLegacyReadDoesNotFallThrough() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let counter = StatuslineTestCounter()
        let client = AntigravityGeminiModelsClient(transport: { _ in
            await counter.increment()
            throw CancellationError()
        }, processList: { throw CancellationError() }, listeningPorts: { _ in [] }, homeDirectory: temp, environment: [:])
        do {
            _ = try await client.fetchGeminiModels()
            XCTFail("已取消的旧来源不得继续")
        } catch is CancellationError {
            let requested = await counter.count
            XCTAssertEqual(requested, 0)
        } catch { XCTFail("取消应原样传播，实际：\(error)") }
    }

    /// 重启前未获得新旧来源读数时，不能用隔期的共享缓存作为通知基线。
    func testLegacyBaselineRemainsPendingAcrossRestartUntilFreshObservation() throws {
        let name = "AntigravityStatuslineTests.Baseline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: GeminiModelsPreferenceKeys.isEnabled)
        defaults.set(true, forKey: UsageNotificationPreferenceKeys.notifiesWhenDepleted)
        let limits = Self.codexLimits()
        let previous = GeminiModelsSnapshot(fetchedAt: Date().addingTimeInterval(-86400), source: .antigravityLocal, groups: [GeminiQuotaGroup(id: "gemini-models", title: "Gemini", windows: [GeminiQuotaWindow(bucketId: "gemini-5h", title: "5h", remainingFraction: 0.72)])])
        let old = UsageSnapshot(fetchedAt: previous.fetchedAt, rateLimits: limits, geminiModels: previous)
        defaults.set(GeminiModelsDataSource.cliStatusline.rawValue, forKey: GeminiModelsPreferenceKeys.dataSource)
        UsageNotificationController(defaults: defaults).seed(with: old)
        XCTAssertTrue(GeminiModelsSettings(defaults: defaults).legacyBaselinePending)
        defaults.set(GeminiModelsDataSource.legacy.rawValue, forKey: GeminiModelsPreferenceKeys.dataSource)
        let restarted = UsageNotificationController(defaults: defaults)
        restarted.seed(with: old)
        let actual = GeminiModelsSnapshot(fetchedAt: Date(), source: .antigravityLocal, groups: [GeminiQuotaGroup(id: "gemini-models", title: "Gemini", windows: [GeminiQuotaWindow(bucketId: "gemini-5h", title: "5h", remainingFraction: 0)])])
        XCTAssertTrue(restarted.process(UsageSnapshot(fetchedAt: Date(), rateLimits: limits, geminiModels: actual)).isEmpty)
        XCTAssertFalse(GeminiModelsSettings(defaults: defaults).legacyBaselinePending)
    }

    /// CLI 模式的额度下降不进入旧 Antigravity 通知与彩带链路，既有 Codex 配额维持。
    func testCLIProjectionDoesNotGenerateAntigravityNotifications() throws {
        let name = "AntigravityStatuslineTests.Notifications.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: GeminiModelsPreferenceKeys.isEnabled)
        defaults.set(GeminiModelsDataSource.cliStatusline.rawValue, forKey: GeminiModelsPreferenceKeys.dataSource)
        defaults.set(true, forKey: UsageNotificationPreferenceKeys.notifiesWhenDepleted)
        let limits = Self.codexLimits()
        let previous = GeminiModelsSnapshot(fetchedAt: Date(), source: .antigravityLocal, groups: [GeminiQuotaGroup(id: "gemini-models", title: "Gemini", windows: [GeminiQuotaWindow(bucketId: "gemini-5h", title: "5h", remainingFraction: 0.72)])])
        let current = GeminiModelsSnapshot(fetchedAt: Date(), source: .antigravityCLIStatusline, groups: [GeminiQuotaGroup(id: "gemini-models", title: "Gemini", windows: [GeminiQuotaWindow(bucketId: "gemini-5h", title: "5h", remainingFraction: 0)])])
        let controller = UsageNotificationController(defaults: defaults)
        controller.seed(with: UsageSnapshot(fetchedAt: Date(), rateLimits: limits, geminiModels: previous))
        XCTAssertTrue(controller.process(UsageSnapshot(fetchedAt: Date(), rateLimits: limits, geminiModels: current)).isEmpty)
    }

    /// 使用互相区分的四桶合成值作为独立真值，避免混用真实账户额度。
    private static func payload() -> Data {
        Data(#"""
        {"product":"antigravity","email":"a@example.invalid","plan_tier":"Google AI Pro","quota":{"gemini-5h":{"remaining_fraction":0.72,"reset_time":"2026-11-26T11:00:00Z"},"gemini-weekly":{"remaining_fraction":0.96,"reset_time":"2026-11-30T09:00:00Z"},"3p-5h":{"remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"},"3p-weekly":{"remaining_fraction":0.5,"reset_time":"2026-12-02T09:00:00Z"}}}
        """#.utf8)
    }

    /// 记录受保护的 Codex 原有字段，CLI 接入不能覆盖它们。
    private static func codexLimits() -> RateLimitSnapshot {
        RateLimitSnapshot(limitId: "codex", limitName: "Codex", primary: RateLimitWindow(usedPercent: 58, windowDurationMins: 300, resetsAt: nil), secondary: RateLimitWindow(usedPercent: 16, windowDurationMins: 10080, resetsAt: nil), credits: nil, planType: "pro", rateLimitReachedType: nil)
    }
}

/// 记录旧供应商客户端真实调用次数，不能依赖 mock 的预设成功判断。
private actor StatuslineTestCounter {
    private(set) var count = 0
    /// 增加一次调用计数。
    func increment() { count += 1 }
}

/// 模拟旧路径，如果误调用会留下可观察计数。
private struct StatuslineCountingLegacy: GeminiModelsUsageFetching {
    let counter: StatuslineTestCounter
    let snapshot: GeminiModelsSnapshot
    /// 返回固定旧来源，并记录调用。
    func fetchGeminiModels() async throws -> GeminiModelsSnapshot {
        await counter.increment()
        return snapshot
    }
}

/// 模拟 Codex 请求失败，证明 CLI 本地读取不依赖网络成功。
private struct StatuslineFailingCodex: UsageRateLimitFetching {
    struct Failure: Error {}
    /// 固定模拟本轮 Codex 网络失败。
    func fetchRateLimits() async throws -> RateLimitSnapshot { throw Failure() }
}

/// 测试中由主执行器明确切换选项，不影响真实 AppStorage。
@MainActor private final class StatuslineSourceState {
    var source: GeminiModelsDataSource = .legacy
    var enabled = true
}

/// 固定 Codex 响应，实际让 ViewModel 走成功保存路径。
private struct StatuslineFixedCodex: UsageRateLimitFetching {
    let limits: RateLimitSnapshot
    /// 返回合成的额度快照。
    func fetchRateLimits() async throws -> RateLimitSnapshot { limits }
}

/// 旧任务故意忽略取消直到测试放行，用于证明发布阶段仍阻止晚到结果。
private actor StatuslineDeferredLegacy: GeminiModelsUsageFetching {
    let snapshot: GeminiModelsSnapshot
    private(set) var hasStarted = false
    private(set) var callCount = 0
    private var released = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    init(snapshot: GeminiModelsSnapshot) { self.snapshot = snapshot }
    /// 先标记调用、等待放行，再返回历史源数据。
    func fetchGeminiModels() async throws -> GeminiModelsSnapshot {
        hasStarted = true
        callCount += 1
        if !released { await withCheckedContinuation { pending.append($0) } }
        return snapshot
    }
    /// 不论有多少重叠调用、任务是否已启动，后续均可正常结束，回归失败也不挂住。
    func release() { released = true; let waiting = pending; pending = []; waiting.forEach { $0.resume() } }
}
