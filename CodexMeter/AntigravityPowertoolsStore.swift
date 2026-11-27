// Antigravity 本机统计独立应用状态；不写 Codex 共享快照、不触发通知、Widget 或供应商请求。
import Combine
import Foundation
import CodexMeterShared

/// 本地读取周期独立于 Codex 供应商网络；仍尊重全局手动模式不后台读取的约定。
enum AntigravityLocalRefresh {
    static let intervalNanoseconds: UInt64 = 300_000_000_000
    /// 自动档一律五分钟本地检查，手动档仅启动与显式交互读取。
    static func interval(for cadence: UsageRefreshCadence) -> UInt64? {
        cadence.intervalNanoseconds == nil ? nil : intervalNanoseconds
    }
}

/// 应用级只读 Powertools 发布源，下拉和设置共用同一结果；加载器可注入，测试不读真实插件文件。
@MainActor
final class AntigravityPowertoolsStore: ObservableObject {
    static let shared = AntigravityPowertoolsStore()
    static let enabledPreferenceKey = "antigravity.powertoolsUsageEnabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var snapshot: PowertoolsUsageSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isRefreshing = false

    private let defaults: UserDefaults
    private let loader: @Sendable () async throws -> PowertoolsUsageSnapshot
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var inFlight: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var active = false
    private var localInterval: UInt64?
    // 这些通知只在主执行器注册；析构时可使用线程安全的注销接口。
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// 默认关闭；只在用户选择统计源且 Antigravity 总开关启用时访问两个既定文件。
    init(defaults: UserDefaults = MenuBarDisplaySettings.sharedDefaults,
         loader: @escaping @Sendable () async throws -> PowertoolsUsageSnapshot = {
             try await Task.detached(priority: .utility) { try PowertoolsUsageReader().load() }.value
         },
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { interval in
             try await Task.sleep(nanoseconds: interval)
         }) {
        self.defaults = defaults
        self.loader = loader
        self.sleep = sleep
        self.isEnabled = defaults.object(forKey: Self.enabledPreferenceKey) as? Bool ?? false
    }

    deinit {
        inFlight?.cancel(); loop?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// 只监听影响本地读取生命周期的偏好；不发布任何旧额度或共享用量通知。
    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.geminiModelsSettingsDidChange, .appBehaviorSettingsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: defaults, queue: .main) { [weak self] _ in
                // 在主执行器同步处理每次启停，避免快速关闭再开启跳过旧代次失效。
                MainActor.assumeIsolated { self?.applyPreferences() }
            })
        }
        applyPreferences()
    }

    /// 显式保存本机统计 opt-in；不使用 Gemini 额度设置通知，避免触发旧网络或 Widget。
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledPreferenceKey)
        applyPreferences()
    }

    /// 当前两个开关同时满足才可读取，与额度来源/模型组及卡片显示位置无关。
    private var canRead: Bool {
        (defaults.object(forKey: Self.enabledPreferenceKey) as? Bool ?? false) && GeminiModelsSettings(defaults: defaults).isEnabled
    }

    /// 在真实启用、停用、自动/手动切换时重建本地循环；无关设置不重启计时或读取。
    func applyPreferences() {
        let opted = defaults.object(forKey: Self.enabledPreferenceKey) as? Bool ?? false
        if isEnabled != opted { isEnabled = opted }
        let enabled = canRead
        let interval = enabled ? AntigravityLocalRefresh.interval(for: AppBehaviorSettings(defaults: defaults).refreshCadence) : nil
        let wasActive = active
        if !enabled {
            // 即便尚未启动周期任务，显式刷新也可能在途；停用必须立即撤销其发布资格。
            active = false; localInterval = nil
            loop?.cancel(); loop = nil
            generation += 1
            inFlight?.cancel(); inFlight = nil
            snapshot = nil; errorMessage = nil; lastCheckedAt = nil; isRefreshing = false
            return
        }
        guard active != enabled || localInterval != interval else { return }
        active = enabled; localInterval = interval
        loop?.cancel(); loop = nil
        // 进入启用状态即读取一次（包括手动档），不因自动/手动档快速切换丢失首次检查。
        if !wasActive {
            let requested = generation
            Task { [weak self] in
                guard let self, self.generation == requested, self.canRead else { return }
                await self.refresh()
            }
        }
        // 周期任务只安排后续检查；不会为已启用来源再启动一次初读。
        if let interval = interval {
            let wait = sleep
            loop = Task { [weak self] in
                guard !Task.isCancelled else { return }
                while !Task.isCancelled {
                    do { try await wait(interval) } catch { return }
                    guard !Task.isCancelled, self != nil else { return }
                    await self?.refresh()
                }
            }
        }
    }

    /// 重入调用合并到同一任务；只有当前代次完成实际读取后才更新检查时间，不伪造源 mtime。
    func refresh() async {
        guard canRead else { return }
        if let task = inFlight { await task.value; return }
        let requested = generation
        let load = loader
        isRefreshing = true
        let task = Task { [weak self] in
            // 尚未开始的取消任务不进入读取器，已启动的有界只读结果仍受下方代次保护。
            guard !Task.isCancelled, self?.canRead == true, self?.generation == requested else { return }
            let result: Result<PowertoolsUsageSnapshot, Error>
            do { result = .success(try await load()) }
            catch { result = .failure(error) }
            guard let self = self, !Task.isCancelled, self.canRead, requested == self.generation else { return }
            self.lastCheckedAt = Date()
            switch result {
            case .success(let value):
                self.snapshot = value; self.errorMessage = nil
            case .failure(let error):
                self.snapshot = nil
                self.errorMessage = (error as? PowertoolsUsageReadError)?.errorDescription ?? "Powertools 统计格式无效，等待有效记录。"
            }
            self.inFlight = nil; self.isRefreshing = false
        }
        inFlight = task
        await task.value
    }
}
