// 官方 Antigravity CLI Statusline 的本地回调、独立快照和用户级配置管理；不访问网络或认证文件。
import Foundation
import CoreFoundation
import Darwin

/// 仅保存官方已知额度桶的可展示字段；不保存原始 Statusline JSON 或会话内容。
struct AntigravityStatuslineBucket: Codable, Equatable {
    let id: String
    let remainingFraction: Double?
    let resetsAt: Date?
    let disabled: Bool
}

/// 单次本机接受的完整观测（空 buckets 表示已知账号等待数据），不是远端实时账本。
struct AntigravityStatuslineFrame: Codable, Equatable {
    let schemaVersion: Int
    let capturedAt: Date
    let accountEmail: String?
    let planName: String?
    let buckets: [AntigravityStatuslineBucket]
}

/// 本地数据或配置操作失败时的有限可解释原因；避免把原始输入/登录材料写到日志或界面。
enum AntigravityStatuslineError: LocalizedError {
    case invalidSnapshot, invalidFile, busy, invalidConfiguration, configurationConflict, configurationChanged, missingCapability

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "CLI 额度快照格式无效，请等待下一次有效回调。"
        case .invalidFile: return "CLI 本地文件不可读写或文件类型不安全。"
        case .busy: return "CLI 额度快照正在更新，请稍后重试。"
        case .invalidConfiguration: return "Antigravity CLI 设置格式无效，未修改配置。"
        case .configurationConflict: return "已有其他 Statusline 配置，CodexMeter 不会覆盖它。"
        case .configurationChanged: return "CLI 配置在编辑期间已变化，请重试。"
        case .missingCapability: return "当前 CodexMeter 安装包缺少 Statusline 回调入口。"
        }
    }
}

/// 固定路径下的有界文件读写；拒绝最终路径上的符号链接和异常文件类型，原子替换前设置文件权限。
private enum AntigravityStatuslineFiles {
    /// lstat 不跟随最后一段符号链接；不存在返回 nil，其余系统错误按失败处理。
    static func attributes(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw AntigravityStatuslineError.invalidFile
    }

    /// 只读取受限大小的普通文件；不存在与损坏/权限失败具有不同语义。
    static func read(_ url: URL, limit: Int) throws -> Data? {
        guard let info = try attributes(url) else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= Int64(limit) else {
            throw AntigravityStatuslineError.invalidFile
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AntigravityStatuslineError.invalidFile }
        defer { _ = close(fd) }
        // 打开后复核实际文件，避免在检查与读取之间被替换为特殊文件而阻塞。
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG else {
            throw AntigravityStatuslineError.invalidFile
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw AntigravityStatuslineError.invalidFile
            }
            if n == 0 { return result }
            guard result.count + n <= limit else { throw AntigravityStatuslineError.invalidFile }
            result.append(contentsOf: buffer.prefix(n))
        }
    }

    /// 确保专用目录是普通目录；仅新建或收紧本应用独占快照目录的权限。
    static func directory(_ url: URL, privateMode: Bool) throws {
        if let info = try attributes(url) {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw AntigravityStatuslineError.invalidFile }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if privateMode {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    /// 在同一个目录中写入唯一普通临时文件，验证目标类型后原子替换；不产生可读的中间半份 JSON。
    static func write(_ data: Data, to url: URL, mode: Int) throws {
        if let info = try attributes(url), (info.st_mode & S_IFMT) != S_IFREG {
            throw AntigravityStatuslineError.invalidFile
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".codexmeter-statusline-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw AntigravityStatuslineError.invalidFile }
        defer { _ = close(fd); _ = unlink(temp.path) }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw AntigravityStatuslineError.invalidFile }
                offset += n
            }
        }
        guard fchmod(fd, mode_t(mode)) == 0, rename(temp.path, url.path) == 0 else {
            throw AntigravityStatuslineError.invalidFile
        }
    }
}

/// 官方回调输入的白名单解析与独立本地事实存储；同一文件只保留最后一份完整观测。
struct AntigravityStatuslineStore {
    static let maximumInputBytes = 1_048_576
    static let knownBuckets = ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]
    let snapshotURL: URL

    /// 允许测试注入专用目录；正常运行使用同一用户的独立快照，不依赖 CWD/App Group。
    init(snapshotURL: URL = AntigravityStatuslineHook.snapshotURL()) {
        self.snapshotURL = snapshotURL
    }

    /// 读取原子落盘后的单份数据；不存在为等待，损坏/未知版本明确抛错，绝不更改采集时间。
    func load() throws -> AntigravityStatuslineFrame? {
        try validateSnapshotParents()
        guard let data = try AntigravityStatuslineFiles.read(snapshotURL, limit: Self.maximumInputBytes) else { return nil }
        guard let frame = try? JSONDecoder().decode(AntigravityStatuslineFrame.self, from: data),
              frame.schemaVersion == 1, frame.capturedAt.timeIntervalSince1970.isFinite,
              Set(frame.buckets.map { $0.id }).count == frame.buckets.count,
              frame.buckets.allSatisfy({ bucket in
                  Self.knownBuckets.contains(bucket.id) &&
                  (bucket.remainingFraction.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
                  (!bucket.disabled || bucket.remainingFraction == nil) &&
                  (bucket.resetsAt.map(Self.validReset) ?? true) &&
                  (bucket.remainingFraction != nil || bucket.resetsAt != nil || bucket.disabled)
              }) else { throw AntigravityStatuslineError.invalidSnapshot }
        return frame
    }

    /// 接受一份合法回调，串行判断账号/空帧后原子保存；返回是否真的更新了本地观测。
    @discardableResult
    func receive(_ data: Data, at capturedAt: Date = Date()) throws -> Bool {
        guard let frame = Self.parse(data, at: capturedAt) else { return false }
        try validateSnapshotParents()
        let directory = snapshotURL.deletingLastPathComponent()
        try AntigravityStatuslineFiles.directory(directory, privateMode: true)
        let lockURL = directory.appendingPathComponent(".cli-statusline-v1.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AntigravityStatuslineError.invalidFile }
        defer { _ = close(fd) }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG else {
            throw AntigravityStatuslineError.invalidFile
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw AntigravityStatuslineError.invalidFile
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw AntigravityStatuslineError.busy }
            usleep(5_000)
        }
        defer { _ = flock(fd, LOCK_UN) }
        let previous = try? load()
        if frame.buckets.isEmpty {
            // 初始化未给新账号时不覆盖旧观测；已知账号切换必须清掉不可归属的旧数据。
            guard let email = frame.accountEmail, email != previous?.accountEmail else { return false }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AntigravityStatuslineFiles.write(encoder.encode(frame), to: snapshotURL, mode: 0o600)
        return true
    }

    /// 复核应用私有目录与它的父目录；拒绝经过这些异常符号链接写入其他目录。
    private func validateSnapshotParents() throws {
        let parent = snapshotURL.deletingLastPathComponent()
        for directory in [parent.deletingLastPathComponent(), parent] {
            if let info = try AntigravityStatuslineFiles.attributes(directory), (info.st_mode & S_IFMT) != S_IFDIR {
                throw AntigravityStatuslineError.invalidFile
            }
        }
    }

    /// 只解析官方声明的 product、quota、套餐/账号与真实数值；不执行或保留其他输入字段。
    private static func parse(_ data: Data, at capturedAt: Date) -> AntigravityStatuslineFrame? {
        guard data.count <= maximumInputBytes, capturedAt.timeIntervalSince1970.isFinite,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["product"] as? String == "antigravity" else { return nil }
        let quotas: [String: Any]
        if let raw = root["quota"] {
            guard let value = raw as? [String: Any] else { return nil }
            quotas = value
        } else {
            quotas = [:]
        }
        let buckets = knownBuckets.compactMap { id -> AntigravityStatuslineBucket? in
            guard let raw = quotas[id] as? [String: Any] else { return nil }
            let disabled: Bool
            if let value = raw["disabled"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
                disabled = number.boolValue
            } else { disabled = false }
            let fraction: Double?
            if !disabled, let number = raw["remaining_fraction"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, (0...1).contains(number.doubleValue) {
                fraction = number.doubleValue
            } else { fraction = nil }
            let reset = absoluteResetDate(raw["reset_time"] as? String)
            guard fraction != nil || reset != nil || disabled else { return nil }
            return AntigravityStatuslineBucket(id: id, remainingFraction: fraction, resetsAt: reset, disabled: disabled)
        }
        return AntigravityStatuslineFrame(schemaVersion: 1, capturedAt: capturedAt,
            accountEmail: boundedText(root["email"], limit: 320)?.lowercased(),
            planName: boundedText(root["plan_tier"], limit: 128), buckets: buckets)
    }

    /// 可选身份字段只接受有限无控制字符的文本，不借用旧身份或推断套餐。
    private static func boundedText(_ value: Any?, limit: Int) -> String? {
        guard let s = value as? String else { return nil }
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= limit,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    /// 严格读取完整 RFC3339 日期；拒绝格式化器会自动归一化的非法日、时分秒和尾随字符。
    /// 支持有/无小数秒及显式时区；无法表示的闰秒、Unix epoch 占位保持未知。
    private static func absoluteResetDate(_ value: String?) -> Date? {
        guard let value = value, value.utf8.count <= 64,
              let pattern = try? NSRegularExpression(pattern: #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?([Zz]|([+-])([0-9]{2}):([0-9]{2}))\z"#),
              let match = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func part(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
        guard let year = part(1).flatMap(Int.init), (1...9999).contains(year),
              let month = part(2).flatMap(Int.init), (1...12).contains(month),
              let day = part(3).flatMap(Int.init), (1...31).contains(day),
              let hour = part(4).flatMap(Int.init), (0...23).contains(hour),
              let minute = part(5).flatMap(Int.init), (0...59).contains(minute),
              let second = part(6).flatMap(Int.init), (0...59).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let local = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: local)
        guard check.year == year, check.month == month, check.day == day, check.hour == hour,
              check.minute == minute, check.second == second else { return nil }
        var offset = 0
        if let sign = part(9) {
            guard let hours = part(10).flatMap(Int.init), (0...23).contains(hours),
                  let minutes = part(11).flatMap(Int.init), (0...59).contains(minutes) else { return nil }
            offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        }
        let fraction = part(7).flatMap { Double("0." + String($0.prefix(9))) } ?? 0
        let date = local.addingTimeInterval(fraction - Double(offset))
        guard validReset(date) else { return nil }
        return date
    }

    /// 持久化输入也必须处于可表示的日期范围，避免下游转 Int 秒数时溢出。
    private static func validReset(_ date: Date) -> Bool {
        let epoch = date.timeIntervalSince1970
        return epoch.isFinite && epoch > 0 && epoch < 253_402_300_800
    }
}

/// 由官方 CLI 自行运行的专用原生入口，必须在 GUI、Updater 及任何网络初始化之前分派。
enum AntigravityStatuslineHook {
    static let argument = "--codexmeter-antigravity-statusline"

    /// 返回用户私有的 canonical 文件位置；主进程和回调使用同一路径。
    static func snapshotURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/CodexMeter/Antigravity/cli-statusline-v1.json")
    }

    /// 有界读取 stdin，正常忽略空/无效帧亦成功退出；真正落盘失败只返回不含输入内容的错误。
    static func run(store: AntigravityStatuslineStore = AntigravityStatuslineStore()) -> Int32 {
        var data = Data()
        while data.count <= AntigravityStatuslineStore.maximumInputBytes {
            let remaining = AntigravityStatuslineStore.maximumInputBytes + 1 - data.count
            let next = FileHandle.standardInput.readData(ofLength: min(remaining, 16_384))
            if next.isEmpty { break }
            data.append(next)
        }
        do {
            _ = try store.receive(data)
            return 0
        } catch {
            let message = Data("CodexMeter: Antigravity statusline snapshot write failed.\n".utf8)
            FileHandle.standardError.write(message)
            return 1
        }
    }
}

/// 区分用户级配置是否可用、需修复或存在其他命令；安装状态不等于 CLI 已产生数据。
enum AntigravityStatuslineInstallationState: Equatable {
    case notInstalled, installed, needsRepair, conflict, invalid
}

/// 仅在用户显式触发时管理自己的 Statusline 块；不读取认证文件、不执行现有设置中的命令。
enum AntigravityStatuslineInstaller {
    static let markerName = "antigravity-statusline-v1.marker"
    static let configurationURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/settings.json")
    private static let maximumConfigBytes = 2 * 1024 * 1024

    /// 计算同一 app bundle 的能力标记；降级至无该资源的旧版不会被回调错误启动。
    static func markerURL(for executableURL: URL) -> URL {
        executableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(markerName)
    }

    /// 按 POSIX shell 字面值引用绝对路径，包括单引号；参数均为安装器的固定字符串。
    private static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// 生成完整自有命令。缺能力标记或可执行文件直接成功退出，内置状态行不受影响。
    static func command(for executableURL: URL) -> String {
        let binary = quoted(executableURL.path)
        return "if [ -f \(quoted(markerURL(for: executableURL).path)) ] && [ -x \(binary) ]; then exec \(binary) \(AntigravityStatuslineHook.argument); else exit 0; fi"
    }

    /// 仅识别安装器产生的完整命令语法及 CodexMeter app 的合法路径，不通过产品名或参数子串判断归属。
    private static func ownedExecutable(_ command: String) -> URL? {
        let suffix = " \(AntigravityStatuslineHook.argument); else exit 0; fi"
        guard command.hasSuffix(suffix), let range = command.range(of: "; then exec ") else { return nil }
        let end = command.index(command.endIndex, offsetBy: -suffix.count)
        guard range.upperBound < end else { return nil }
        let literal = String(command[range.upperBound..<end])
        guard literal.hasPrefix("'"), literal.hasSuffix("'"), literal.count >= 2 else { return nil }
        let path = String(literal.dropFirst().dropLast()).replacingOccurrences(of: "'\"'\"'", with: "'")
        guard path.hasPrefix("/"), quoted(path) == literal else { return nil }
        let url = URL(fileURLWithPath: path)
        let macOS = url.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard url.lastPathComponent == "CodexMeter", macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app", self.command(for: url) == command else { return nil }
        return url
    }

    /// 读取官方用户级设置的根对象及原始字节，只用于保全其他配置和写前并发复核；不记录正文。
    private static func read(_ url: URL) throws -> (Data?, [String: Any]) {
        guard let data = try AntigravityStatuslineFiles.read(url, limit: maximumConfigBytes) else { return (nil, [:]) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityStatuslineError.invalidConfiguration
        }
        return (data, object)
    }

    /// 官方字段可以省略并使用默认值，但显式类型损坏时禁止安装、修复或移除。
    private static func validBlock(_ line: [String: Any]) -> Bool {
        if let type = line["type"], (type as? String) != "command" { return false }
        for key in ["enabled", "stack_with_default"] {
            if let value = line[key] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            }
        }
        if let value = line["padding"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, number.doubleValue >= 0,
                number.doubleValue.rounded(.towardZero) == number.doubleValue else { return false }
        }
        return true
    }

    /// 检查 Statusline 是否由本应用管理及是否指向当前路径；异常格式不静默覆盖。
    private static func state(_ value: Any?, executableURL: URL?) -> AntigravityStatuslineInstallationState {
        guard let value = value else { return .notInstalled }
        guard let line = value as? [String: Any], let text = line["command"] as? String, validBlock(line) else { return .invalid }
        guard let old = ownedExecutable(text) else { return .conflict }
        guard let executableURL = executableURL else { return .invalid }
        if old.path == executableURL.path, line["type"] as? String == "command", line["enabled"] as? Bool == true,
           line["stack_with_default"] as? Bool == true,
           FileManager.default.isExecutableFile(atPath: executableURL.path), FileManager.default.fileExists(atPath: markerURL(for: executableURL).path) { return .installed }
        return .needsRepair
    }

    /// 公开只读状态检测，损坏或权限问题归为 invalid 而非未安装。
    static func status(at url: URL = configurationURL, executableURL: URL? = Bundle.main.executableURL) -> AntigravityStatuslineInstallationState {
        do { return state(try read(url).1["statusLine"], executableURL: executableURL) }
        catch { return .invalid }
    }

    /// 只写本应用的 block；设置在读写之间改变时拒绝覆盖，保留原有文件权限及全部其他键。
    private static func save(_ object: [String: Any], original: Data?, at url: URL) throws {
        try AntigravityStatuslineFiles.directory(url.deletingLastPathComponent(), privateMode: false)
        guard try AntigravityStatuslineFiles.read(url, limit: maximumConfigBytes) == original else {
            throw AntigravityStatuslineError.configurationChanged
        }
        let attributes = try AntigravityStatuslineFiles.attributes(url)
        // 原子 rename 不应绕过用户显式设置的只读权限/ACL；失败时不覆盖原文件。
        if let existing = attributes {
            guard (existing.st_mode & 0o222) != 0, FileManager.default.isWritableFile(atPath: url.path) else {
                throw AntigravityStatuslineError.invalidFile
            }
        }
        guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw AntigravityStatuslineError.invalidFile
        }
        let mode = attributes.map { Int($0.st_mode & 0o777) } ?? 0o600
        let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard output.count <= maximumConfigBytes else { throw AntigravityStatuslineError.invalidConfiguration }
        try AntigravityStatuslineFiles.write(output, to: url, mode: mode)
    }

    /// 用户点击安装/修复时建立自有 Statusline；拒绝第三方配置，重复正常安装不写文件。
    static func install(at url: URL = configurationURL, executableURL: URL? = Bundle.main.executableURL) throws {
        guard let exe = executableURL, ownedExecutable(command(for: exe)) != nil,
              FileManager.default.isExecutableFile(atPath: exe.path), FileManager.default.fileExists(atPath: markerURL(for: exe).path) else {
            throw AntigravityStatuslineError.missingCapability
        }
        let (original, loaded) = try read(url)
        var object = loaded
        switch state(object["statusLine"], executableURL: exe) {
        case .installed: return
        case .conflict: throw AntigravityStatuslineError.configurationConflict
        case .invalid: throw AntigravityStatuslineError.invalidConfiguration
        case .notInstalled, .needsRepair: break
        }
        var line = object["statusLine"] as? [String: Any] ?? [:]
        line["type"] = "command"; line["command"] = command(for: exe); line["enabled"] = true; line["stack_with_default"] = true
        object["statusLine"] = line
        try save(object, original: original, at: url)
    }

    /// 仅移除已确认归属自己的块；不清除已有额度文件、其他设置或用户登录状态。
    static func remove(at url: URL = configurationURL, executableURL: URL? = Bundle.main.executableURL) throws {
        let (original, loaded) = try read(url)
        var object = loaded
        guard let value = object["statusLine"] else { return }
        guard let line = value as? [String: Any], let text = line["command"] as? String, validBlock(line) else {
            throw AntigravityStatuslineError.invalidConfiguration
        }
        guard ownedExecutable(text) != nil else { throw AntigravityStatuslineError.configurationConflict }
        object.removeValue(forKey: "statusLine")
        try save(object, original: original, at: url)
    }
}

#if swift(>=5.5)
extension AntigravityStatuslineBucket: Sendable {}
extension AntigravityStatuslineFrame: Sendable {}
extension AntigravityStatuslineStore: Sendable {}
extension AntigravityStatuslineInstallationState: Sendable {}
#endif
