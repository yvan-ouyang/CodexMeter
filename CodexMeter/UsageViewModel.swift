import CodexMeterShared
import Foundation
import OSLog
@preconcurrency import UserNotifications
import WidgetKit

/// 标记触发系统通知的额度供应商，确保 Codex 与 Antigravity 的提醒文案可区分。
enum UsageNotificationProvider: String, Equatable, Sendable {
    case codex
    case antigravity

    var title: String {
        switch self {
        case .codex:
            "Codex"
        case .antigravity:
            "Antigravity"
        }
    }
}

/// 描述一次需要交付给系统通知中心的额度变化。
enum UsageNotificationEvent: Equatable, Sendable {
    case depleted(provider: UsageNotificationProvider, windowTitle: String)
    case lowRemaining(provider: UsageNotificationProvider, windowTitle: String, remainingText: String)
    case reset(provider: UsageNotificationProvider, windowTitle: String)

    /// 返回事件所属厂商，供投递前按厂商总开关做最终复核。
    var provider: UsageNotificationProvider {
        switch self {
        case let .depleted(provider, _):
            provider
        case let .lowRemaining(provider, _, _):
            provider
        case let .reset(provider, _):
            provider
        }
    }
}

/// 只在额度向下跨过边界时生成事件，避免每次轮询重复通知。
enum UsageNotificationEventResolver {
    /// 比较相邻快照并返回需要发送的通知；额度恢复或边界内波动不会重复触发。
    static func events(
        previous: RateLimitSnapshot,
        current: RateLimitSnapshot,
        settings: UsageNotificationSettings,
        provider: UsageNotificationProvider = .codex
    ) -> [UsageNotificationEvent] {
        let windows = [
            (previous.primary, current.primary),
            (previous.secondary, current.secondary)
        ]

        return windows.compactMap { previousWindow, currentWindow in
            guard let previousWindow, let currentWindow else {
                return nil
            }
            let previousRemaining = previousWindow.remainingPercent
            let currentRemaining = currentWindow.remainingPercent
            guard currentRemaining < previousRemaining else {
                return nil
            }
            if settings.notifiesWhenDepleted, previousRemaining > 0, currentRemaining == 0 {
                return .depleted(provider: provider, windowTitle: currentWindow.durationLabel)
            }
            if settings.notifiesWhenLow,
               previousRemaining > settings.lowRemainingThreshold,
               currentRemaining <= settings.lowRemainingThreshold
            {
                return .lowRemaining(
                    provider: provider,
                    windowTitle: currentWindow.durationLabel,
                    remainingText: currentWindow.remainingPercentText
                )
            }
            return nil
        }
    }

    /// 比较 Antigravity 各模型组的同一额度窗口，避免把不同供应商或不同模型组混为一谈。
    static func geminiEvents(
        previous: GeminiModelsSnapshot,
        current: GeminiModelsSnapshot,
        settings: UsageNotificationSettings
    ) -> [UsageNotificationEvent] {
        let previousWindows = previous.groups.reduce(into: [String: GeminiQuotaWindow]()) { result, group in
            for window in group.windows {
                result["\(group.id)|\(window.bucketId)"] = window
            }
        }

        return current.groups.flatMap { group in
            group.windows.compactMap { window in
                let key = "\(group.id)|\(window.bucketId)"
                guard let previousWindow = previousWindows[key],
                      let previousRemaining = previousWindow.remainingPercent,
                      let currentRemaining = window.remainingPercent,
                      currentRemaining < previousRemaining
                else {
                    return nil
                }

                let windowTitle = "\(group.title) · \(window.title)"
                if settings.notifiesWhenDepleted, previousRemaining > 0, currentRemaining == 0 {
                    return .depleted(provider: .antigravity, windowTitle: windowTitle)
                }
                if settings.notifiesWhenLow,
                   previousRemaining > settings.lowRemainingThreshold,
                   currentRemaining <= settings.lowRemainingThreshold
                {
                    return .lowRemaining(
                        provider: .antigravity,
                        windowTitle: windowTitle,
                        remainingText: window.remainingPercentText ?? "--"
                    )
                }
                return nil
            }
        }
    }
}

/// 描述一次已确认的额度窗口重置，供彩带和系统通知分别决定是否消费。
struct UsageResetEvent: Equatable, Sendable {
    let kind: UsageResetCelebrationOption
    let windowTitle: String
}

/// 持久化额度重置检测基线，使睡眠和应用重启后的首次刷新仍能识别真实重置。
struct UsageResetCelebrationDetector {
    private struct State: Codable {
        let wasAboveThreshold: Bool
        let resetBoundary: Int?
    }

    private enum ResetKind: String {
        case session
        case weekly
    }

    private struct ResetObservation {
        let key: String
        let kind: ResetKind
        let window: RateLimitWindow
        let windowTitle: String
    }

    private static let defaultsKey = "celebrations.resetDetectorStates.v1"
    private let defaultsKey: String
    private static let threshold = 1.0

    private let defaults: UserDefaults
    private var states: [String: State]

    /// 从偏好存储恢复检测基线；不同供应商使用独立命名空间，损坏数据按空状态处理。
    init(defaults: UserDefaults, namespace: String = "codex") {
        self.defaults = defaults
        self.defaultsKey = namespace == "codex"
            ? Self.defaultsKey
            : "celebrations.resetDetectorStates.\(namespace).v1"
        if let data = defaults.data(forKey: self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: State].self, from: data)
        {
            self.states = decoded
        } else {
            self.states = [:]
        }
    }

    /// 仅在缺少持久化状态时用缓存快照建立基线，避免启动时覆盖更可靠的跨进程记录。
    mutating func seed(with rateLimits: RateLimitSnapshot?) {
        guard let rateLimits else { return }
        seed(observations: observations(in: rateLimits))
    }

    /// 为 Antigravity 的模型额度建立独立检测基线，避免与 Codex 的同周期窗口互相覆盖。
    mutating func seed(with geminiSnapshot: GeminiModelsSnapshot?) {
        guard let geminiSnapshot else { return }
        seed(observations: observations(in: geminiSnapshot))
    }

    /// 清除当前厂商的持久化检测基线；重新启用后首份快照只用于建立新基线。
    mutating func reset() {
        guard !states.isEmpty || defaults.object(forKey: defaultsKey) != nil else { return }
        states.removeAll()
        defaults.removeObject(forKey: defaultsKey)
    }

    /// 只为尚未记录的额度窗口写入检测基线，避免启动时覆盖可靠的跨进程状态。
    private mutating func seed(observations: [ResetObservation]) {
        var changed = false
        for observation in observations where states[observation.key] == nil {
            states[observation.key] = State(
                wasAboveThreshold: observation.window.usedPercent > Self.threshold,
                resetBoundary: observation.window.resetsAt
            )
            changed = true
        }
        if changed {
            persist()
        }
    }

    /// 更新持久化检测状态，并在用量跨过阈值且重置边界前移时返回是否应播放彩带。
    mutating func process(_ rateLimits: RateLimitSnapshot, option: UsageResetCelebrationOption) -> Bool {
        processKind(rateLimits, option: option) != nil
    }

    /// 更新 Antigravity 检测状态，并在模型额度重置时返回是否应播放彩带。
    mutating func process(_ geminiSnapshot: GeminiModelsSnapshot, option: UsageResetCelebrationOption) -> Bool {
        processKind(geminiSnapshot, option: option) != nil
    }

    /// 返回本次快照确认的全部窗口重置，调用方可按产品和窗口分别发送通知。
    mutating func processEvents(_ rateLimits: RateLimitSnapshot) -> [UsageResetEvent] {
        process(observations: observations(in: rateLimits), option: .both)
    }

    /// 返回 Antigravity 本次快照确认的全部窗口重置，调用方可保留模型组名称。
    mutating func processEvents(_ geminiSnapshot: GeminiModelsSnapshot) -> [UsageResetEvent] {
        process(observations: observations(in: geminiSnapshot), option: .both)
    }

    /// 更新 Codex 检测状态，并返回触发彩带的窗口类型；无重置时返回 nil。
    mutating func processKind(
        _ rateLimits: RateLimitSnapshot,
        option: UsageResetCelebrationOption
    ) -> UsageResetCelebrationOption? {
        preferredKind(
            from: process(observations: observations(in: rateLimits), option: option)
        )
    }

    /// 更新 Antigravity 检测状态，并返回触发彩带的窗口类型；无重置时返回 nil。
    mutating func processKind(
        _ geminiSnapshot: GeminiModelsSnapshot,
        option: UsageResetCelebrationOption
    ) -> UsageResetCelebrationOption? {
        preferredKind(
            from: process(observations: observations(in: geminiSnapshot), option: option)
        )
    }

    /// 在多个重置事件中选出彩带展示类型；同轮同时重置时周窗口优先。
    private func preferredKind(from events: [UsageResetEvent]) -> UsageResetCelebrationOption? {
        events.first(where: { $0.kind == .weekly })?.kind ?? events.first?.kind
    }

    /// 统一处理不同供应商的窗口观察值，并持久化跨重启的重置基线。
    private mutating func process(
        observations: [ResetObservation],
        option: UsageResetCelebrationOption
    ) -> [UsageResetEvent] {
        var resetEvents: [UsageResetEvent] = []
        for observation in observations {
            let previous = states[observation.key]
            let isAboveThreshold = observation.window.usedPercent > Self.threshold
            let boundaryAdvanced = previous?.resetBoundary.flatMap { previousBoundary in
                observation.window.resetsAt.map { $0 > previousBoundary }
            } ?? false
            let crossedBelowThreshold = previous?.wasAboveThreshold == true && !isAboveThreshold
            let suppressedCrossing = crossedBelowThreshold && !boundaryAdvanced

            if crossedBelowThreshold, boundaryAdvanced, includes(observation.kind, in: option) {
                let candidate: UsageResetCelebrationOption
                switch observation.kind {
                case .session:
                    candidate = .session
                case .weekly:
                    candidate = .weekly
                }
                resetEvents.append(
                    UsageResetEvent(kind: candidate, windowTitle: observation.windowTitle)
                )
            }
            states[observation.key] = State(
                wasAboveThreshold: suppressedCrossing ? true : isAboveThreshold,
                resetBoundary: boundaryAdvanced
                    ? observation.window.resetsAt
                    : previous?.resetBoundary ?? observation.window.resetsAt
            )
        }
        persist()
        return resetEvents
    }

    /// 按接口实际窗口时长区分会话与周额度，兼容只有 primary 周窗口的账号。
    private func observations(in rateLimits: RateLimitSnapshot) -> [ResetObservation] {
        [rateLimits.primary, rateLimits.secondary].compactMap { window in
            guard let window else { return nil }
            let kind: ResetKind = window.isWeeklyQuotaWindow ? .weekly : .session
            return ResetObservation(
                key: kind.rawValue,
                kind: kind,
                window: window,
                windowTitle: window.durationLabel
            )
        }
    }

    /// 将 Antigravity 支持的 5 小时和 7 天窗口转换为统一的重置观察值。
    private func observations(in snapshot: GeminiModelsSnapshot) -> [ResetObservation] {
        snapshot.groups.flatMap { group in
            group.windows.compactMap { quotaWindow in
                guard let window = quotaWindow.rateLimitWindow else {
                    return nil
                }
                let kind: ResetKind = window.isWeeklyQuotaWindow ? .weekly : .session
                return ResetObservation(
                    key: "\(group.id)|\(quotaWindow.bucketId)",
                    kind: kind,
                    window: window,
                    windowTitle: "\(group.title) · \(quotaWindow.title)"
                )
            }
        }
    }

    /// 判断当前用户选项是否包含指定重置类型。
    private func includes(_ kind: ResetKind, in option: UsageResetCelebrationOption) -> Bool {
        switch kind {
        case .session:
            option.celebratesSessionReset
        case .weekly:
            option.celebratesWeeklyReset
        }
    }

    /// 将小型检测状态写入共享偏好，供下次启动和唤醒后的刷新继续使用。
    private func persist() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

/// 在后台发送最小 Codex 请求；只消费 Codex 的 5 小时重置事件，不处理 Antigravity。
enum CodexSessionStarter {
    static let arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "ok"]
    private static let logger = Logger(subsystem: "com.jinsihou.CodexMeter", category: "Automation")

    /// 仅在用户开启自动化且本轮包含 5 小时重置时启动下一周期。
    static func shouldStart(after events: [UsageResetEvent], defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: UsageAutomationPreferenceKeys.startsSessionAfterReset)
            && events.contains(where: { $0.kind == .session })
    }

    /// 从 GUI 应用可用的 PATH 和常见安装位置寻找 Codex，并在后台执行一次。
    static func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let codexBinary = environment["CODEX_BIN"]
            process.executableURL = URL(fileURLWithPath: codexBinary ?? "/usr/bin/env")
            process.arguments = codexBinary == nil ? ["codex"] + arguments : arguments
            var processEnvironment = environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            processEnvironment["PATH"] = [
                environment["PATH"],
                home + "/.local/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin"
            ].compactMap { $0 }.joined(separator: ":")
            process.environment = processEnvironment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    logger.error("自动启动下一额度周期失败；状态=\(process.terminationStatus)")
                    return
                }
                logger.info("已向 Codex 发送 ok，下一额度周期已启动。")
            } catch {
                logger.error("自动启动下一额度周期失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// 跨通知中心异步回调保存 Antigravity 投递代次，切源后撤销尚未交付的旧事件。
private final class AntigravityNotificationGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    /// 读取当前代次供投递请求捕获。
    func current() -> Int { lock.withLock { generation } }
    /// 使先前所有尚未交付的请求失效。
    func invalidate() { lock.withLock { generation += 1 } }
}

/// 把用量边界事件交给 macOS 通知中心；权限请求只由用户主动开启设置时触发。
@MainActor
final class UsageNotificationController {
    private var previousRateLimits: RateLimitSnapshot?
    private var previousGeminiModels: GeminiModelsSnapshot?
    private let antigravityGeneration = AntigravityNotificationGeneration()
    private var resetCelebrationDetector: UsageResetCelebrationDetector
    private var geminiResetCelebrationDetector: UsageResetCelebrationDetector
    private let defaults: UserDefaults
    private let playConfetti: (UsageResetCelebrationOption) -> Void

    /// 注入带窗口类型的彩带播放动作，使重置判断保持可测试且不依赖窗口实现。
    init(
        defaults: UserDefaults = MenuBarDisplaySettings.sharedDefaults,
        playConfetti: @escaping (UsageResetCelebrationOption) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.resetCelebrationDetector = UsageResetCelebrationDetector(defaults: defaults)
        self.geminiResetCelebrationDetector = UsageResetCelebrationDetector(
            defaults: defaults,
            namespace: "antigravity"
        )
        self.playConfetti = playConfetti
    }

    /// 用已有缓存建立比较基线，避免应用启动后的第一次刷新被误判为额度下降。
    func seed(with snapshot: UsageSnapshot?) {
        previousRateLimits = snapshot?.rateLimits
        resetCelebrationDetector.seed(with: snapshot?.rateLimits)
        let settings = GeminiModelsSettings(defaults: defaults)
        if settings.usesLegacySource && !settings.legacyBaselinePending {
            previousGeminiModels = snapshot?.geminiModels.flatMap { settings.accepts($0.source) ? $0 : nil }
            geminiResetCelebrationDetector.seed(with: previousGeminiModels)
        } else {
            disableAntigravity()
        }
    }

    /// 停用 Antigravity 的通知生命周期，并删除跨刷新保存的比较基线。
    func disableAntigravity() {
        antigravityGeneration.invalidate()
        if GeminiModelsSettings(defaults: defaults).dataSource != .legacy {
            defaults.set(true, forKey: GeminiModelsPreferenceKeys.legacyBaselinePending)
        }
        previousGeminiModels = nil
        geminiResetCelebrationDetector.reset()
    }

    /// 处理新快照并返回本轮生成的通知事件；Antigravity 总开关同时决定其通知和彩带是否生效。
    @discardableResult
    func process(_ snapshot: UsageSnapshot) -> [UsageNotificationEvent] {
        let current = snapshot.rateLimits
        let previousCodex = previousRateLimits
        let previousGemini = previousGeminiModels
        let geminiSettings = GeminiModelsSettings(defaults: defaults)
        let geminiEnabled = geminiSettings.usesLegacySource
        let currentLegacyGemini = snapshot.geminiModels.flatMap { geminiEnabled && geminiSettings.accepts($0.source) ? $0 : nil }
        let establishLegacyBaseline = geminiEnabled && geminiSettings.legacyBaselinePending && currentLegacyGemini != nil
        defer {
            previousRateLimits = current
            previousGeminiModels = currentLegacyGemini
        }
        let celebrationOption = UsageResetCelebrationOption(
            rawValue: defaults.string(
                forKey: UsageCelebrationPreferenceKeys.resetOption
            ) ?? ""
        ) ?? .off
        let settings = UsageNotificationSettings(defaults: defaults)
        if !geminiEnabled {
            disableAntigravity()
        }
        let codexResetEvents = resetCelebrationDetector.processEvents(current)
        if CodexSessionStarter.shouldStart(after: codexResetEvents, defaults: defaults) {
            CodexSessionStarter.start()
        }
        let geminiResetEvents: [UsageResetEvent]
        if establishLegacyBaseline {
            geminiResetCelebrationDetector.reset()
            geminiResetCelebrationDetector.seed(with: currentLegacyGemini)
            defaults.removeObject(forKey: GeminiModelsPreferenceKeys.legacyBaselinePending)
            geminiResetEvents = []
        } else if let geminiSnapshot = currentLegacyGemini {
            geminiResetEvents = geminiResetCelebrationDetector.processEvents(geminiSnapshot)
        } else {
            geminiResetEvents = []
        }
        let resetKinds = (codexResetEvents + geminiResetEvents).map(\.kind)
        let celebrationType = resetKinds.first(where: {
            $0 == .weekly && celebrationOption.celebratesWeeklyReset
        }) ?? resetKinds.first(where: {
            $0 == .session && celebrationOption.celebratesSessionReset
        })
        if let celebrationType {
            playConfetti(celebrationType)
        }
        var events: [UsageNotificationEvent] = []
        if settings.notifiesWhenReset {
            events += codexResetEvents.map {
                .reset(provider: .codex, windowTitle: $0.windowTitle)
            }
            events += geminiResetEvents.map {
                .reset(provider: .antigravity, windowTitle: $0.windowTitle)
            }
        }
        if let previousCodex {
            events += UsageNotificationEventResolver.events(
                previous: previousCodex,
                current: current,
                settings: settings
            )
        }
        if geminiEnabled, !establishLegacyBaseline,
           let previousGemini,
           let currentGemini = currentLegacyGemini
        {
            events += UsageNotificationEventResolver.geminiEvents(
                previous: previousGemini,
                current: currentGemini,
                settings: settings
            )
        }
        guard !events.isEmpty else {
            return []
        }

        Self.enqueueNotifications(events, gate: antigravityGeneration, generation: antigravityGeneration.current())
        return events
    }

    /// 在系统通知回调队列复核权限、来源及投递代次；切源后不交付在途旧 Antigravity 事件。
    private nonisolated static func enqueueNotifications(_ events: [UsageNotificationEvent], gate: AntigravityNotificationGeneration, generation: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let authorization = settings.authorizationStatus
            guard authorization == .authorized || authorization == .provisional else {
                return
            }
            Task { @MainActor in
                let geminiEnabled = GeminiModelsSettings(defaults: MenuBarDisplaySettings.sharedDefaults).usesLegacySource
                    && gate.current() == generation
                for event in events where event.provider != .antigravity || geminiEnabled {
                    let content = UNMutableNotificationContent()
                switch event {
                case let .depleted(provider, windowTitle):
                    content.title = "\(provider.title) 额度已耗尽"
                    content.body = "\(windowTitle)窗口已无剩余额度。"
                case let .lowRemaining(provider, windowTitle, remainingText):
                    content.title = "\(provider.title) 额度偏低"
                    content.body = "\(windowTitle)窗口剩余 \(remainingText)。"
                case let .reset(provider, windowTitle):
                    content.title = "\(provider.title) · \(windowTitle) 已重置"
                    content.body = "额度已恢复，可继续使用。"
                }
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "CodexMeter.usage.\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
                    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
                }
            }
        }
    }

    /// 用户开启任一提醒时请求 alert 与 sound 权限，拒绝后不反复弹窗。
    static func requestAuthorization() {
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

}

/// 描述本机统计相对于当前读取周期的新鲜度，供界面区分实时结果与保留缓存。
enum LocalCodexUsageFreshness: Equatable, Sendable {
    case current
    case cached
    case failed
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var localCodexUsage: LocalCodexUsageSnapshot?
    @Published private(set) var localCodexUsageFreshness = LocalCodexUsageFreshness.current
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var geminiSnapshot: GeminiModelsSnapshot?
    @Published private(set) var geminiErrorMessage: String?
    // 本地检查完成时刻与 CLI 回调的真实观测时间独立，不能因反复读取而伪造额度更新。
    @Published private(set) var cliLastCheckedAt: Date?
    @Published private(set) var isRefreshingCLIStatusline = false

    private let client: any UsageRateLimitFetching
    private let geminiClient: any GeminiModelsUsageFetching
    private let statuslineClient: any GeminiModelsUsageFetching
    private let store: UsageSnapshotStore
    private let reloadWidgetTimelines: () -> Void
    private let refreshCadenceProvider: @MainActor @Sendable () -> UsageRefreshCadence
    private let resetCreditsVisibilityProvider: @MainActor @Sendable () -> Bool
    private let geminiSettingsProvider: @MainActor @Sendable () -> GeminiModelsSettings
    private let processUsageNotifications: @MainActor @Sendable (UsageSnapshot) -> Void
    private let onGeminiDisabled: @MainActor @Sendable () -> Void
    private let localCodexUsageLoader: @Sendable () async -> LocalCodexUsageSnapshot?
    private let logger = Logger(subsystem: "com.jinsihou.CodexMeter", category: "Usage")
    private var refreshTask: Task<Void, Never>?
    private var geminiRefreshTask: Task<GeminiModelsSnapshot, Error>?
    private var geminiRefreshGeneration = 0
    private var lastGeminiDataSource: GeminiModelsDataSource
    private var lastGeminiEnabled: Bool
    private var awaitingLegacyBaseline = false
    private var cliRawSnapshot: GeminiModelsSnapshot?
    private var cliReadTask: Task<Void, Never>?
    private var cliReadEnabled = false
    private var cliReadInterval: UInt64?
    private var cliDisplayTask: Task<Void, Never>?
    private var hasStartedRefreshLoop = false
    private var isRefreshingLocalUsage = false
    private var appBehaviorObserver: NSObjectProtocol?
    private var popoverDisplayObserver: NSObjectProtocol?
    private var geminiSettingsObserver: NSObjectProtocol?
    private var cliRefreshObserver: NSObjectProtocol?
    private var lastShowsResetCredits: Bool

    init(
        client: any UsageRateLimitFetching = DirectCodexUsageClient(),
        store: UsageSnapshotStore = UsageSnapshotStore(),
        reloadWidgetTimelines: @escaping () -> Void = {
            DispatchQueue.global(qos: .utility).async {
                WidgetCenter.shared.reloadTimelines(ofKind: "CodexMeterWidget")
                WidgetCenter.shared.reloadTimelines(ofKind: "CodexLocalUsageWidget")
            }
        },
        refreshCadenceProvider: @escaping @MainActor @Sendable () -> UsageRefreshCadence = {
            AppBehaviorSettings(defaults: MenuBarDisplaySettings.sharedDefaults).refreshCadence
        },
        resetCreditsVisibilityProvider: @escaping @MainActor @Sendable () -> Bool = {
            PopoverDisplaySettings(defaults: MenuBarDisplaySettings.sharedDefaults).showsResetCredits
        },
        geminiClient: any GeminiModelsUsageFetching = AntigravityGeminiModelsClient(),
        statuslineClient: any GeminiModelsUsageFetching = AntigravityStatuslineUsageClient(),
        geminiSettingsProvider: @escaping @MainActor @Sendable () -> GeminiModelsSettings = {
            GeminiModelsSettings(defaults: MenuBarDisplaySettings.sharedDefaults)
        },
        processUsageNotifications: @escaping @MainActor @Sendable (UsageSnapshot) -> Void = { _ in },
        onGeminiDisabled: @escaping @MainActor @Sendable () -> Void = {},
        localCodexUsageLoader: @escaping @Sendable () async -> LocalCodexUsageSnapshot? = {
            await LocalCodexUsageReader().load()
        }
    ) {
        self.client = client
        self.geminiClient = geminiClient
        self.statuslineClient = statuslineClient
        self.lastGeminiDataSource = geminiSettingsProvider().dataSource
        self.lastGeminiEnabled = geminiSettingsProvider().isEnabled
        self.awaitingLegacyBaseline = geminiSettingsProvider().legacyBaselinePending
        self.store = store
        self.reloadWidgetTimelines = reloadWidgetTimelines
        self.refreshCadenceProvider = refreshCadenceProvider
        self.resetCreditsVisibilityProvider = resetCreditsVisibilityProvider
        self.geminiSettingsProvider = geminiSettingsProvider
        self.processUsageNotifications = processUsageNotifications
        self.onGeminiDisabled = onGeminiDisabled
        self.localCodexUsageLoader = localCodexUsageLoader
        self.lastShowsResetCredits = resetCreditsVisibilityProvider()
        if let cachedSnapshot = try? store.load() {
            self.snapshot = cachedSnapshot
            // CLI 模式只认独立本地文件；旧共享缓存仍属于原有来源。
            let currentGeminiSettings = geminiSettingsProvider()
            self.geminiSnapshot = currentGeminiSettings.usesLegacySource && !awaitingLegacyBaseline
                ? cachedSnapshot.geminiModels.flatMap { currentGeminiSettings.accepts($0.source) ? $0 : nil } : nil
            if let cachedLocalUsage = cachedSnapshot.localCodexUsage {
                // 共享缓存不保存任务标题；启动后先展示最近成功的统计，任务明细等待本次读取补齐。
                self.localCodexUsage = LocalCodexUsageSnapshot(
                    summary: cachedLocalUsage,
                    taskBoard: LocalCodexTaskBoard(items: [], fallbackCounts: cachedLocalUsage.taskCounts)
                )
                self.localCodexUsageFreshness = .cached
            }
        } else {
            self.snapshot = nil
        }
    }

    deinit {
        refreshTask?.cancel()
        geminiRefreshTask?.cancel()
        cliReadTask?.cancel()
        cliDisplayTask?.cancel()
    }

    var menuBarTitle: String {
        [snapshot?.rateLimits.primary, snapshot?.rateLimits.secondary]
            .compactMap { $0 }
            .map { "\($0.compactDurationLabel) \($0.remainingPercentText)" }
            .joined(separator: "\n")
    }

    var menuBarPrimaryTitle: String {
        "\(menuBarPrimaryLabel) \(menuBarPrimaryValue)"
    }

    var menuBarSecondaryTitle: String {
        "\(menuBarSecondaryLabel) \(menuBarSecondaryValue)"
    }

    var menuBarPrimaryLabel: String {
        snapshot?.rateLimits.primary?.compactDurationLabel ?? "quota"
    }

    var menuBarPrimaryValue: String {
        guard let rateLimits = snapshot?.rateLimits else {
            return "--"
        }
        return rateLimits.primary?.remainingPercentText ?? "--"
    }

    var menuBarSecondaryLabel: String {
        snapshot?.rateLimits.secondary?.compactDurationLabel ?? "quota"
    }

    var menuBarSecondaryValue: String {
        guard let rateLimits = snapshot?.rateLimits else {
            return "--"
        }
        return rateLimits.secondary?.remainingPercentText ?? "--"
    }

    var menuBarPrimaryTone: UsageRemainingTone {
        Self.tone(for: snapshot?.rateLimits.primary?.remainingPercent)
    }

    var menuBarSecondaryTone: UsageRemainingTone {
        Self.tone(for: snapshot?.rateLimits.secondary?.remainingPercent)
    }

    var menuHeaderPrimaryText: String {
        guard let window = snapshot?.rateLimits.primary else {
            return "用量窗口剩余 --"
        }
        return "\(window.durationLabel)剩余 \(window.remainingPercentText)"
    }

    var menuHeaderSecondaryText: String {
        guard let window = snapshot?.rateLimits.secondary else {
            return "用量窗口剩余 --"
        }
        return "\(window.durationLabel)剩余 \(window.remainingPercentText)"
    }

    var statusSymbolName: String {
        if errorMessage != nil {
            return "exclamationmark.triangle"
        }
        if isRefreshing {
            return "arrow.triangle.2.circlepath"
        }
        return "gauge.with.needle"
    }

    var planType: String {
        snapshot?.rateLimits.planType ?? "--"
    }

    var isStale: Bool {
        guard let snapshot else {
            return false
        }
        return Date().timeIntervalSince(snapshot.fetchedAt) > 120
    }

    func start() {
        guard !hasStartedRefreshLoop else {
            return
        }

        hasStartedRefreshLoop = true
        observeAppBehaviorSettings()
        observePopoverDisplaySettings()
        observeGeminiSettings()
        cliRefreshObserver = NotificationCenter.default.addObserver(forName: .antigravityCLIStatuslineRefreshRequested, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshCLIStatuslineIfSelected() }
        }
        let initialGeminiSettings = geminiSettingsProvider()
        if !initialGeminiSettings.isEnabled {
            disableGeminiModels()
        } else if initialGeminiSettings.usesCLIStatusline {
            // CLI 数据不参与旧来源通知，即使从历史版本带着比较基线启动。
            onGeminiDisabled()
        }
        applyRefreshCadence()
        Task { [weak self] in
            await self?.refreshLocalCodexUsage()
        }
        // 本地已有缓存时也要唤醒 WidgetKit，避免上一次空时间线继续显示“暂无数据”。
        if snapshot != nil {
            reloadWidgetTimelines()
        }
    }

    func refresh() async {
        let localUsageTask = Task { [weak self] in
            await self?.refreshLocalCodexUsage()
        }
        await refresh(forceRefreshResetCredits: false)
        await localUsageTask.value
    }

    /// 串行刷新本机统计并合并进已有额度缓存；读取失败时保留最近一次成功结果。
    func refreshLocalCodexUsage() async {
        guard !isRefreshingLocalUsage else { return }
        isRefreshingLocalUsage = true
        defer { isRefreshingLocalUsage = false }
        guard let loadedLocalCodexUsage = await localCodexUsageLoader() else {
            localCodexUsageFreshness = .failed
            return
        }
        localCodexUsage = loadedLocalCodexUsage
        localCodexUsageFreshness = .current
        guard let cachedSnapshot = snapshot else { return }
        guard cachedSnapshot.localCodexUsage != loadedLocalCodexUsage.summary else { return }
        let updatedSnapshot = cachedSnapshot.withLocalCodexUsage(loadedLocalCodexUsage.summary)
        try? store.save(updatedSnapshot)
        snapshot = updatedSnapshot
        NotificationCenter.default.post(name: .usageSnapshotDidChange, object: updatedSnapshot)
        reloadWidgetTimelines()
    }

    /// 用户主动刷新重置卡时绕过每日缓存，确保测试机上已经发放的卡能被立刻补读出来。
    func refreshResetCredits() async {
        await refresh(forceRefreshResetCredits: true)
    }

    /// 下拉框打开时补齐重置卡数据；只有数量但缺少到期明细时，也绕过当天缓存重读一次。
    func refreshResetCreditsIfNeeded() async {
        let resetCredits = snapshot?.resetCredits
        let needsResetCreditsRefresh = resetCredits == nil
            || (resetCredits?.availableCount ?? 0) > 0 && resetCredits?.credits.isEmpty == true
        guard resetCreditsVisibilityProvider(), needsResetCreditsRefresh else {
            return
        }
        // 打开下拉已有独立的 CLI 检查任务；补读 Codex 重置卡不重复读取本地额度。
        await refresh(forceRefreshResetCredits: true, readsCLI: false)
    }

    /// CLI 模式先独立读取本地快照；Codex 网络成功或失败均不得替换它或把它写入共享缓存。
    private func refresh(forceRefreshResetCredits: Bool, readsCLI: Bool = true) async {
        synchronizeGeminiSource()
        if readsCLI { await refreshCLIStatuslineIfSelected() }
        logger.info("Refresh started")
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let networkSnapshot = try await client.fetchUsageSnapshot(forceRefreshResetCredits: forceRefreshResetCredits)
            // 旧来源保留原有刷新顺序；明确 CLI 模式不触发旧客户端。
            if geminiSettingsProvider().usesLegacySource || !geminiSettingsProvider().isEnabled {
                _ = await refreshGeminiSnapshotIfEnabled()
            }
            synchronizeGeminiSource()
            let current = geminiSettingsProvider()
            let sharedGemini: GeminiModelsSnapshot? = current.usesLegacySource
                ? matchingGeminiSnapshot(for: current)
                : (current.isEnabled ? legacySharedGeminiSnapshot : nil)
            let updatedSnapshot = networkSnapshot.withLocalCodexUsage(
                localCodexUsage?.summary ?? snapshot?.localCodexUsage
            ).withGeminiModels(sharedGemini)
            try store.save(updatedSnapshot)
            snapshot = updatedSnapshot
            if current.usesLegacySource { geminiSnapshot = sharedGemini }
            NotificationCenter.default.post(name: .usageSnapshotDidChange, object: updatedSnapshot)
            processUsageNotifications(updatedSnapshot)
            errorMessage = nil
            logger.info("Refresh saved snapshot")
            reloadWidgetTimelines()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Refresh failed: \(self.errorMessage ?? "unknown", privacy: .public)")
            let restoredCachedSnapshot = snapshot == nil
            if snapshot == nil { snapshot = try? store.load() }
            synchronizeGeminiSource()
            let current = geminiSettingsProvider()
            if current.usesLegacySource { geminiSnapshot = matchingGeminiSnapshot(for: current) }
            if restoredCachedSnapshot, snapshot != nil {
                reloadWidgetTimelines()
            }
        }
    }

    /// 共享缓存只承载已有旧来源；防御未知或误传的 CLI 数据进入旧 Widget 兼容契约。
    private var legacySharedGeminiSnapshot: GeminiModelsSnapshot? {
        guard let cached = snapshot?.geminiModels, cached.source != .antigravityCLIStatusline else { return nil }
        return cached
    }

    /// 获取当前选择允许的展示值。CLI 模式绝不从旧共享缓存兜底。
    private func matchingGeminiSnapshot(for settings: GeminiModelsSettings) -> GeminiModelsSnapshot? {
        if let displayed = geminiSnapshot, settings.accepts(displayed.source) { return displayed }
        if settings.usesLegacySource && !awaitingLegacyBaseline { return legacySharedGeminiSnapshot }
        return nil
    }

    /// 切换来源时立即取消在途结果、移除旧展示并重置 Antigravity 通知基线，不改 Codex 数据。
    private func synchronizeGeminiSource() {
        let selected = geminiSettingsProvider()
        guard selected.dataSource != lastGeminiDataSource || selected.isEnabled != lastGeminiEnabled else { return }
        let switchedSource = selected.dataSource != lastGeminiDataSource
        lastGeminiDataSource = selected.dataSource
        lastGeminiEnabled = selected.isEnabled
        if switchedSource && selected.dataSource == .legacy { awaitingLegacyBaseline = true }
        if selected.legacyBaselinePending { awaitingLegacyBaseline = true }
        geminiRefreshGeneration += 1
        geminiRefreshTask?.cancel()
        geminiRefreshTask = nil
        cliRawSnapshot = nil
        cliLastCheckedAt = nil
        isRefreshingCLIStatusline = false
        cliDisplayTask?.cancel()
        cliDisplayTask = nil
        geminiSnapshot = nil
        geminiErrorMessage = nil
        onGeminiDisabled()
        NotificationCenter.default.post(name: .antigravityCLIStatuslineDidChange, object: nil)
    }

    /// 发布 CLI 本地观测；只更新独立展示，不保存/通知 Codex 或 Widget。
    private func publishCLI(_ raw: GeminiModelsSnapshot?, error: String? = nil) {
        cliRawSnapshot = raw
        geminiErrorMessage = error
        cliLastCheckedAt = Date()
        isRefreshingCLIStatusline = false
        geminiSnapshot = raw.map { AntigravityStatuslinePresentation.project($0) }
        publishCLIViewState()
        scheduleCLIProjection()
    }

    /// 同一份展示状态供设置预览消费；纯时钟投影仍携带原检查时间，不产生新观测。
    private func publishCLIViewState() {
        var info: [AnyHashable: Any] = [:]
        if let error = geminiErrorMessage { info["error"] = error }
        if let checkedAt = cliLastCheckedAt { info["checkedAt"] = checkedAt }
        NotificationCenter.default.post(name: .antigravityCLIStatuslineDidChange, object: geminiSnapshot, userInfo: info)
    }

    /// 仅在显示的 CLI 快照有未来时间边界时安排一次重绘；不读取文件，不向 Google 请求。
    private func scheduleCLIProjection() {
        cliDisplayTask?.cancel()
        cliDisplayTask = nil
        guard geminiSettingsProvider().usesCLIStatusline, let raw = cliRawSnapshot else { return }
        let now = Date()
        let ageBoundary = raw.fetchedAt.addingTimeInterval(AntigravityStatuslinePresentation.staleAfter)
        let futureBoundaries = ([ageBoundary] + raw.groups.flatMap { $0.windows.compactMap(\.resetsAt) })
            .filter { $0 > now && $0 <= ageBoundary }
        guard !AntigravityStatuslinePresentation.isStale(raw, now: now), let next = futureBoundaries.min() else { return }
        // 边界过后重新投影，让手动与五分钟档的旧数据也不会被误当实时额度。
        cliDisplayTask = Task { [weak self] in
            let delay = max(0.01, next.timeIntervalSinceNow + 0.02)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.refreshCLIProjection()
        }
    }

    /// 时间跨过期或重置边界时重算显示；调度下一次仅本地重绘。
    private func refreshCLIProjection() {
        guard geminiSettingsProvider().usesCLIStatusline, let raw = cliRawSnapshot else { return }
        geminiSnapshot = AntigravityStatuslinePresentation.project(raw)
        publishCLIViewState()
        scheduleCLIProjection()
    }

    /// 打开面板、手动刷新或独立本地定时器调用；旧路径不会通过此入口触发。
    func refreshCLIStatuslineIfSelected() async {
        guard geminiSettingsProvider().usesCLIStatusline else { return }
        _ = await refreshGeminiSnapshotIfEnabled()
    }

    /// 按显式来源刷新；完成后同时核对当前选择和代次，禁止已取消的旧任务发布。
    private func refreshGeminiSnapshotIfEnabled() async -> GeminiModelsSnapshot? {
        synchronizeGeminiSource()
        let requested = geminiSettingsProvider()
        guard requested.isEnabled else { disableGeminiModels(); return nil }
        guard requested.usesLegacySource || requested.usesCLIStatusline else {
            geminiSnapshot = nil
            geminiErrorMessage = AppLocalization.string("请选择有效的 Antigravity 数据来源。")
            return nil
        }
        if requested.usesCLIStatusline, let existingTask = geminiRefreshTask {
            // 多个界面/定时入口共享同一轮本地读取，不反复取消或启动新的旧来源请求。
            let existingGeneration = geminiRefreshGeneration
            _ = try? await existingTask.value
            let current = geminiSettingsProvider()
            guard existingGeneration == geminiRefreshGeneration, current.usesCLIStatusline else { return nil }
            return matchingGeminiSnapshot(for: current)
        }
        geminiRefreshTask?.cancel()
        geminiRefreshGeneration += 1
        let generation = geminiRefreshGeneration
        if requested.usesCLIStatusline { isRefreshingCLIStatusline = true }
        let selectedClient = requested.usesCLIStatusline ? statuslineClient : geminiClient
        let task = Task {
            try Task.checkCancellation()
            return try await selectedClient.fetchGeminiModels()
        }
        geminiRefreshTask = task
        defer {
            if generation == geminiRefreshGeneration {
                geminiRefreshTask = nil
                if requested.usesCLIStatusline { isRefreshingCLIStatusline = false }
            }
        }
        do {
            let fetched = try await task.value
            let current = geminiSettingsProvider()
            guard generation == geminiRefreshGeneration, current.dataSource == requested.dataSource else {
                return matchingGeminiSnapshot(for: current)
            }
            guard current.isEnabled else { disableGeminiModels(); return nil }
            guard current.accepts(fetched.source) else { throw AntigravityStatuslineError.invalidSnapshot }
            if current.usesCLIStatusline {
                publishCLI(fetched)
            } else {
                awaitingLegacyBaseline = false
                geminiSnapshot = fetched
                geminiErrorMessage = nil
            }
            return geminiSnapshot
        } catch {
            let current = geminiSettingsProvider()
            guard generation == geminiRefreshGeneration, current.dataSource == requested.dataSource else {
                return matchingGeminiSnapshot(for: current)
            }
            guard current.isEnabled else { disableGeminiModels(); return nil }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if current.usesCLIStatusline {
                // 正常关闭 CLI 文件仍可读；损坏/明确等待时不得冒充旧账号或旧源。
                publishCLI(nil, error: message)
            } else {
                geminiErrorMessage = message
                geminiSnapshot = matchingGeminiSnapshot(for: current)
            }
            return geminiSnapshot
        }
    }

    /// 既有旧源才合并共享缓存；CLI 快照可以没有 Codex 账号或网络数据而独立显示。
    private func refreshGeminiModels() async {
        // CLI 入口只读本地状态，即使读取期间切回旧来源也不会代替旧源保存共享缓存。
        if geminiSettingsProvider().usesCLIStatusline {
            await refreshCLIStatuslineIfSelected()
            return
        }
        let refreshed = await refreshGeminiSnapshotIfEnabled()
        let current = geminiSettingsProvider()
        guard current.usesLegacySource, let refreshed = refreshed, current.accepts(refreshed.source),
              let currentSnapshot = snapshot else { return }
        let updatedSnapshot = currentSnapshot.withGeminiModels(refreshed)
        guard updatedSnapshot != currentSnapshot || current.legacyBaselinePending else { return }
        if current.legacyBaselinePending {
            // 首次切回旧来源仅在新观测已成功落盘后消费持久化基线；失败仍保留独立内存读数。
            do { try store.save(updatedSnapshot) }
            catch { return }
        } else {
            try? store.save(updatedSnapshot)
        }
        snapshot = updatedSnapshot
        processUsageNotifications(updatedSnapshot)
        NotificationCenter.default.post(name: .usageSnapshotDidChange, object: updatedSnapshot)
        reloadWidgetTimelines()
    }

    /// 关闭 Antigravity 后取消读取、清空运行状态，并只从共享快照中移除该厂商数据。
    private func disableGeminiModels() {
        geminiRefreshGeneration += 1
        geminiRefreshTask?.cancel()
        geminiRefreshTask = nil
        cliRawSnapshot = nil
        cliLastCheckedAt = nil
        isRefreshingCLIStatusline = false
        cliDisplayTask?.cancel()
        cliDisplayTask = nil
        geminiSnapshot = nil
        geminiErrorMessage = nil
        onGeminiDisabled()
        NotificationCenter.default.post(name: .antigravityCLIStatuslineDidChange, object: nil)

        guard let currentSnapshot = snapshot else { return }
        let updatedSnapshot = currentSnapshot.withGeminiModels(nil)
        guard updatedSnapshot != currentSnapshot else { return }
        try? store.save(updatedSnapshot)
        snapshot = updatedSnapshot
        NotificationCenter.default.post(name: .usageSnapshotDidChange, object: updatedSnapshot)
        reloadWidgetTimelines()
    }

    private static func tone(for remainingPercent: Int?) -> UsageRemainingTone {
        UsageRemainingTone(remainingPercent: remainingPercent)
    }

    /// 监听 Gemini 独立配置；模型或开关变化时只刷新 Gemini，不重复请求 Codex。
    private func observeGeminiSettings() {
        guard geminiSettingsObserver == nil else {
            return
        }
        geminiSettingsObserver = NotificationCenter.default.addObserver(
            forName: .geminiModelsSettingsDidChange,
            object: MenuBarDisplaySettings.sharedDefaults,
            queue: .main
        ) { [weak self] _ in
            // 同步失效旧来源，随后再异步读取，防止菜单栏重建时短暂展示错源数据。
            MainActor.assumeIsolated {
                self?.synchronizeGeminiSource()
                // 本通知下方已有单次刷新入口；周期任务不再安排第二个初读。
                self?.reconcileCLIReadLoop(requestInitial: false)
            }
            Task { @MainActor in await self?.refreshGeminiModels() }
        }
    }

    /// 监听设置页里刷新频率的变化；只关心本 app 的偏好通知，避免 UserDefaults 全局噪声反复重启任务。
    private func observeAppBehaviorSettings() {
        guard appBehaviorObserver == nil else {
            return
        }
        appBehaviorObserver = NotificationCenter.default.addObserver(
            forName: .appBehaviorSettingsDidChange,
            object: MenuBarDisplaySettings.sharedDefaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyRefreshCadence()
            }
        }
    }

    /// 监听下拉面板模块开关；重置卡从隐藏恢复显示时，立即补一次真实接口请求。
    private func observePopoverDisplaySettings() {
        guard popoverDisplayObserver == nil else {
            return
        }
        lastShowsResetCredits = resetCreditsVisibilityProvider()
        popoverDisplayObserver = NotificationCenter.default.addObserver(
            forName: .popoverDisplaySettingsDidChange,
            object: MenuBarDisplaySettings.sharedDefaults,
            queue: .main
        ) { [weak self] notification in
            let notifiedShowsResetCredits = notification.userInfo?[PopoverPreferenceKeys.showsResetCredits] as? Bool
            Task { @MainActor in
                guard let self else {
                    return
                }
                let showsResetCredits = notifiedShowsResetCredits ?? self.resetCreditsVisibilityProvider()
                let previousShowsResetCredits = self.lastShowsResetCredits
                self.lastShowsResetCredits = showsResetCredits
                guard showsResetCredits, !previousShowsResetCredits else {
                    return
                }
                await self.refresh(forceRefreshResetCredits: true)
            }
        }
    }

    /// 独立维护 CLI 五分钟读取任务；自动档之间切换不会重启本地计时，手动档不保留定时读取。
    private func reconcileCLIReadLoop(requestInitial: Bool = true) {
        let enabled = geminiSettingsProvider().usesCLIStatusline
        let interval = enabled ? AntigravityLocalRefresh.interval(for: refreshCadenceProvider()) : nil
        guard cliReadEnabled != enabled || cliReadInterval != interval else { return }
        let wasEnabled = cliReadEnabled
        cliReadEnabled = enabled; cliReadInterval = interval
        cliReadTask?.cancel(); cliReadTask = nil
        guard enabled else { return }
        if requestInitial && !wasEnabled {
            let requestedGeneration = geminiRefreshGeneration
            Task { [weak self] in
                guard let self, self.geminiRefreshGeneration == requestedGeneration else { return }
                await self.refreshCLIStatuslineIfSelected()
            }
        }
        guard let interval else { return }
        cliReadTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard !Task.isCancelled, self != nil else { return }
                await self?.refreshCLIStatuslineIfSelected()
            }
        }
    }

    /// Codex 继续沿用其原刷新周期；CLI 本地检查独立调度，不受网络请求阻塞。
    private func applyRefreshCadence() {
        refreshTask?.cancel()
        refreshTask = nil
        reconcileCLIReadLoop()
        let cadence = refreshCadenceProvider().intervalNanoseconds
        guard let intervalNanoseconds = cadence else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(forceRefreshResetCredits: false, readsCLI: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard !Task.isCancelled else { return }
                await self.refresh(forceRefreshResetCredits: false, readsCLI: false)
            }
        }
    }
}
