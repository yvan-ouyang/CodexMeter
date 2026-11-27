// Powertools 的生命周期、供应商 Tab 和旧数据隔离回归；全部使用隔离偏好与合成读取器。
import Foundation
import XCTest
@testable import CodexMeterShared

@MainActor
final class AntigravityPowertoolsTests: XCTestCase {
    /// 真实打开默认 Antigravity，打开期间的合法选择不因重新构建宿主改变。
    func testProviderTabResetsOnlyOnRealOpenAndFallsBackWhenHidden() {
        let state = PopoverProviderSelection()
        state.open(antigravityVisible: true, goVisible: false)
        XCTAssertEqual(state.tabs, [.antigravity, .codex])
        XCTAssertEqual(state.selected, .antigravity)
        state.select(.codex)
        state.reconcile(antigravityVisible: true, goVisible: true)
        XCTAssertEqual(state.tabs, [.antigravity, .codex, .openCodeGo])
        XCTAssertEqual(state.selected, .codex)
        state.open(antigravityVisible: true, goVisible: true)
        XCTAssertEqual(state.selected, .antigravity)
        state.reconcile(antigravityVisible: false, goVisible: true)
        XCTAssertEqual(state.selected, .codex)
        state.select(.antigravity)
        XCTAssertEqual(state.selected, .codex)
        state.select(.openCodeGo)
        state.reconcile(antigravityVisible: false, goVisible: false)
        XCTAssertEqual(state.tabs, [.codex]); XCTAssertEqual(state.selected, .codex)
    }

    /// 自动档使用统一本地5分钟，手动档没有后台定时读取，Codex 自己的 interval 不变。
    func testLocalCadenceDoesNotRewriteGlobalCadence() {
        XCTAssertEqual(AntigravityLocalRefresh.interval(for: .seconds30), 300_000_000_000)
        XCTAssertEqual(AntigravityLocalRefresh.interval(for: .minute1), 300_000_000_000)
        XCTAssertEqual(AntigravityLocalRefresh.interval(for: .minutes5), 300_000_000_000)
        XCTAssertNil(AntigravityLocalRefresh.interval(for: .manual))
        XCTAssertEqual(UsageRefreshCadence.seconds30.intervalNanoseconds, 30_000_000_000)
    }

    /// 实际自动循环只安排五分钟睡眠；手动档启动一次但没有后台定时器。
    func testActualScheduledLocalReadUsesFiveMinutes() async throws {
        for cadence in [UsageRefreshCadence.seconds30, .manual] {
            let suite = "PowertoolsSchedule.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: GeminiModelsPreferenceKeys.isEnabled)
            defaults.set(true, forKey: AntigravityPowertoolsStore.enabledPreferenceKey)
            defaults.set(cadence.rawValue, forKey: AppBehaviorPreferenceKeys.refreshCadence)
            let probe = PowertoolsReadProbe(snapshot: try fixture())
            let schedule = PowertoolsSleepProbe()
            let store = AntigravityPowertoolsStore(defaults: defaults, loader: { await probe.read() }, sleep: { interval in
                await schedule.record(interval)
                // 记录真实调度参数后结束本轮，不在 CI 等待实际五分钟。
                throw CancellationError()
            })
            store.start()
            for _ in 0..<100 {
                let scheduled = await schedule.values
                if store.snapshot != nil && (cadence == .manual || !scheduled.isEmpty) { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let reads = await probe.count
            let intervals = await schedule.values
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(intervals, cadence == .manual ? [] : [300_000_000_000])
            if cadence == .manual {
                // 取消尚未开始的自动档循环，手动模式不应偷偷增加后台检查。
                defaults.set(UsageRefreshCadence.seconds30.rawValue, forKey: AppBehaviorPreferenceKeys.refreshCadence)
                store.applyPreferences()
                defaults.set(UsageRefreshCadence.manual.rawValue, forKey: AppBehaviorPreferenceKeys.refreshCadence)
                store.applyPreferences()
                try await Task.sleep(nanoseconds: 20_000_000)
                let afterSwitch = await probe.count
                let afterIntervals = await schedule.values
                XCTAssertEqual(afterSwitch, 1)
                XCTAssertTrue(afterIntervals.isEmpty)
            }
            store.setEnabled(false)
        }
    }

    /// 默认关闭不读取真实文件；启用且总开关打开才读，关闭后清空已显示数据。
    func testOptInAndMasterSwitchProtectIndependentUsage() async throws {
        let suite = "PowertoolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: GeminiModelsPreferenceKeys.isEnabled)
        defaults.set(UsageRefreshCadence.manual.rawValue, forKey: AppBehaviorPreferenceKeys.refreshCadence)
        let probe = PowertoolsReadProbe(snapshot: try fixture())
        let store = AntigravityPowertoolsStore(defaults: defaults, loader: { await probe.read() })
        await store.refresh()
        let initial = await probe.count
        XCTAssertEqual(initial, 0)
        XCTAssertNil(store.snapshot)
        store.setEnabled(true)
        await store.refresh()
        XCTAssertEqual(store.snapshot?.summary(for: .retained).totals.totalTokens, 60)
        XCTAssertNotNil(store.lastCheckedAt)
        defaults.set(false, forKey: GeminiModelsPreferenceKeys.isEnabled)
        store.applyPreferences()
        await store.refresh()
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.isEnabled, "总开关保留显式统计偏好")
    }

    /// 同一在途读取只执行一次；禁用后的晚到成功结果不重新显示。
    func testConcurrentReadsCoalesceAndLateResultCannotPublish() async throws {
        let suite = "PowertoolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: GeminiModelsPreferenceKeys.isEnabled)
        defaults.set(true, forKey: AntigravityPowertoolsStore.enabledPreferenceKey)
        defaults.set(UsageRefreshCadence.manual.rawValue, forKey: AppBehaviorPreferenceKeys.refreshCadence)
        let probe = PowertoolsReadProbe(snapshot: try fixture(), held: true)
        let store = AntigravityPowertoolsStore(defaults: defaults, loader: { await probe.read() })
        let first = Task { await store.refresh() }
        for _ in 0..<100 { if await probe.count > 0 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        guard await probe.count > 0 else {
            await probe.release(); await first.value
            return XCTFail("合成读取未启动")
        }
        // 在主执行器直接进入第二次 refresh，停用与放行任务只有在它挂起后才能运行。
        let stop = Task { @MainActor in
            store.setEnabled(false)
            await probe.release()
        }
        await store.refresh()
        await first.value; await stop.value
        let reads = await probe.count
        XCTAssertEqual(reads, 1)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.lastCheckedAt)
        XCTAssertFalse(store.isRefreshing)
    }

    /// 创建同一个可独立核对的真实临时计量缓存；不碰用户的缓存或配置。
    private func fixture() throws -> PowertoolsUsageSnapshot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PowertoolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let row: [String: Any] = ["id": "synthetic", "timestampMs": Date().timeIntervalSince1970 * 1000,
                                  "model": "Gemini 4 Neon", "inputTokens": 10, "cacheReadTokens": 20, "outputTokens": 30]
        let data = try JSONSerialization.data(withJSONObject: [row])
        try data.write(to: dir.appendingPathComponent("usage-history-cache.json"))
        return try PowertoolsUsageReader(directoryURL: dir).load()
    }
}

/// 记录测试循环实际请求的间隔，不使用真正五分钟延时。
private actor PowertoolsSleepProbe {
    private(set) var values: [UInt64] = []
    /// 每次调度记录其纳秒参数。
    func record(_ interval: UInt64) { values.append(interval) }
}

/// 可控读取完成时机，真实计数用于检测重复刷新和停用后的在途发布。
private actor PowertoolsReadProbe {
    let snapshot: PowertoolsUsageSnapshot
    private let held: Bool
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0

    /// 默认即时读取，需要验证取消时才让测试暂缓完成。
    init(snapshot: PowertoolsUsageSnapshot, held: Bool = false) { self.snapshot = snapshot; self.held = held }

    /// 记录一次实际读取并可忽略取消直到测试放行，检验发布代次而非只检验 Task.cancel。
    func read() async -> PowertoolsUsageSnapshot {
        count += 1
        if held && !released { await withCheckedContinuation { waiters.append($0) } }
        return snapshot
    }

    /// 解除所有正在等待的读任务，保证失败测试也能正常退出。
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
