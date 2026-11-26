// 合成数据驱动的独立核心测试：使用真实文件、命令执行和配置读写，无需 Xcode/XCTest。
import Foundation
import Dispatch

/// 测试失败同时记录断言语义，便于本机定位实际失败而不是只报告退出码。
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// 支持可能抛错的条件断言；失败不影响后续独立用例运行。
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

// 子进程调用真实 Hook stdin 路径，唯一输出目标为父测试指定的临时目录。
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--test-hook" {
    exit(AntigravityStatuslineHook.run(store: AntigravityStatuslineStore(snapshotURL: URL(fileURLWithPath: CommandLine.arguments[2]))))
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let t = ISO8601DateFormatter().date(from: "2026-11-26T09:00:00Z")!
let a = "a@example.invalid"
let b = "b@example.invalid"
let quota: [String: Any] = [
    "gemini-5h": ["remaining_fraction": 0.72, "reset_time": "2026-11-26T11:00:00Z"],
    "gemini-weekly": ["remaining_fraction": 0.96, "reset_time": "2026-11-30T09:00:00Z"],
    "3p-5h": ["remaining_fraction": 1, "reset_time": "1970-01-01T00:00:00Z"],
    "3p-weekly": ["remaining_fraction": 0.50, "reset_time": "2026-12-02T09:00:00Z"]
]

/// 构造官方 Statusline 形态的数据；敏感样例值是明显的合成标记，不能进入快照。
func frame(_ buckets: [String: Any], email: String? = a, plan: String? = "Google AI Pro") throws -> Data {
    var obj: [String: Any] = ["product": "antigravity", "quota": buckets, "cwd": "NEVER_STORE_WORKSPACE", "conversation_title": "NEVER_STORE_PROMPT", "access_token": "NEVER_STORE_SECRET"]
    if let email = email { obj["email"] = email }
    if let plan = plan { obj["plan_tier"] = plan }
    return try JSONSerialization.data(withJSONObject: obj)
}

/// 创建独立的测试快照位置，不接触真实用户缓存。
func makeStore(_ name: String) -> AntigravityStatuslineStore {
    AntigravityStatuslineStore(snapshotURL: root.appendingPathComponent(name).appendingPathComponent("cli-statusline-v1.json"))
}

/// 按原始桶 ID 读取结果，避免依赖数组顺序掩盖错位。
func bucket(_ key: String, from value: AntigravityStatuslineFrame?) -> AntigravityStatuslineBucket? {
    value?.buckets.first(where: { $0.id == key })
}

/// 读本轮合成设置 JSON，仅验证保全字段和实际命令内容。
func config(_ file: URL) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
        throw CheckFailure(description: "配置不是 JSON 对象")
    }
    return obj
}

/// 创建模拟新版 app 和 capability marker；实际执行的是无副作用的本地测试脚本。
func fakeApp(_ name: String) throws -> URL {
    let contents = root.appendingPathComponent(name).appendingPathComponent("CodexMeter.app/Contents")
    let binary = contents.appendingPathComponent("MacOS/CodexMeter")
    let marker = AntigravityStatuslineInstaller.markerURL(for: binary)
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nprintf '%s' \"$1\"\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    try Data("1\n".utf8).write(to: marker)
    return binary
}

/// 调用已生成的安装命令，检测 marker 防护及真实 shell 路径引用。
func execute(_ command: String) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

var passed = 0
var failed = 0
/// 独立执行一个场景并输出清晰的可核验证据。
func run(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS: \(name)") }
    catch { failed += 1; fputs("FAIL: \(name): \(error)\n", stderr) }
}

run("AG-01b 原生 Hook 子进程仅接收 stdin") {
    let local = makeStore("native")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--test-hook", local.snapshotURL.path]
    let input = Pipe(), output = Pipe()
    process.standardInput = input; process.standardOutput = output
    try process.run()
    input.fileHandleForWriting.write(try frame(quota))
    input.fileHandleForWriting.closeFile()
    let visible = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try expect(process.terminationStatus == 0 && visible.isEmpty, "原生入口正常接受且不打印个人数据")
    try expect(try local.load()?.buckets.count == 4, "原生 Hook 必须实际落盘四桶")
}

run("AG-01 四窗口精确映射、私有快照和重读时间") {
    let store = makeStore("four")
    try expect(try store.load() == nil, "首次读取应等待")
    try expect(try store.receive(frame(quota), at: t), "完整帧应该接受")
    let result = try store.load()
    try expect(result?.capturedAt == t && result?.accountEmail == a && result?.planName == "Google AI Pro", "来自本次帧的身份、套餐和时间")
    try expect(result?.buckets.count == 4, "恰好四个桶")
    try expect(bucket("gemini-5h", from: result)?.remainingFraction == 0.72, "Gemini 短窗口")
    try expect(bucket("gemini-weekly", from: result)?.remainingFraction == 0.96, "Gemini 周窗口")
    try expect(bucket("3p-5h", from: result)?.remainingFraction == 1, "Claude/GPT 100% 有效")
    try expect(bucket("3p-weekly", from: result)?.remainingFraction == 0.5, "Claude/GPT 周窗口")
    try expect(bucket("gemini-5h", from: result)?.resetsAt == t.addingTimeInterval(7200), "绝对重置时间")
    try expect(bucket("3p-5h", from: result)?.resetsAt == nil, "epoch 不得被当成重置时间")
    let onDisk = try String(contentsOf: store.snapshotURL, encoding: .utf8)
    try expect(!onDisk.contains("NEVER_STORE"), "不得保留原始凭据/路径/对话字段")
    let mode = try FileManager.default.attributesOfItem(atPath: store.snapshotURL.path)[.posixPermissions] as? NSNumber
    try expect(mode?.intValue == 0o600, "快照文件仅本用户可读写")
    try expect(try store.load()?.capturedAt == t, "再次读取不得修改采集时间")
}

run("AG-02 空初始化、账号切换、零与未知值") {
    let store = makeStore("accounts")
    _ = try store.receive(frame(quota), at: t)
    try expect(try !store.receive(frame([:], email: a), at: t.addingTimeInterval(1)), "同账号空帧不覆盖")
    try expect(try !store.receive(frame([:], email: nil, plan: nil), at: t.addingTimeInterval(2)), "未知身份空初始化不覆盖")
    try expect(try store.load()?.capturedAt == t, "空帧不刷新时间")
    try expect(try store.receive(frame([:], email: b, plan: nil), at: t.addingTimeInterval(3)), "已知新账号空帧写等待状态")
    let waiting = try store.load()
    try expect(waiting?.accountEmail == b && waiting?.buckets.isEmpty == true, "不得把 A 的额度归给 B")
    let partial: [String: Any] = ["gemini-5h": ["remaining_fraction": 0, "reset_time": "2026-11-26T11:00:00.125Z"], "3p-weekly": ["disabled": true, "remaining_fraction": 0.9], "gemini-weekly": ["remaining_fraction": true], "3p-5h": ["remaining_amount": 42], "unknown": ["remaining_fraction": 0.33]]
    _ = try store.receive(frame(partial, email: b, plan: nil), at: t.addingTimeInterval(4))
    let value = try store.load()
    try expect(value?.accountEmail == b && value?.planName == nil, "不继承上次套餐")
    try expect(bucket("gemini-5h", from: value)?.remainingFraction == 0, "真实 0% 必须保留")
    try expect(bucket("gemini-5h", from: value)?.resetsAt == t.addingTimeInterval(7200.125), "支持小数秒时间")
    try expect(bucket("3p-weekly", from: value)?.disabled == true && bucket("3p-weekly", from: value)?.remainingFraction == nil, "禁用不能伪造余额")
    try expect(bucket("gemini-weekly", from: value)?.remainingFraction == nil && bucket("3p-5h", from: value)?.remainingFraction == nil, "布尔值和无分母不能映射比例")
    try expect(bucket("unknown", from: value) == nil, "未知桶不得猜测")
    _ = try store.receive(frame(quota, email: nil, plan: nil), at: t.addingTimeInterval(5))
    try expect(try store.load()?.accountEmail == nil, "有效未知账号帧不借用 B 身份")
    _ = try store.receive(frame([:], email: a), at: t.addingTimeInterval(6))
    try expect(try store.load()?.buckets.isEmpty == true, "不能将未知身份数据归给新 A")
}

run("AG-03 坏帧、并发、损坏恢复和重复观测") {
    let store = makeStore("recovery")
    _ = try store.receive(frame(quota), at: t)
    for invalid in [Data("{broken".utf8), Data("{\"product\":\"other\",\"quota\":{}}".utf8), Data("{\"product\":\"antigravity\",\"quota\":[]}".utf8), Data(repeating: 65, count: 2 * 1024 * 1024)] {
        try expect(try !store.receive(invalid, at: t.addingTimeInterval(2)), "非法/超限帧应忽略")
    }
    try expect(try store.load()?.capturedAt == t, "坏帧不改变旧观测")
    _ = try store.receive(frame(quota), at: t.addingTimeInterval(3))
    try expect(try store.load()?.capturedAt == t.addingTimeInterval(3), "合法同值回调仍是新观测")
    try Data("invalid cache".utf8).write(to: store.snapshotURL)
    var rejected = false
    do { _ = try store.load() } catch { rejected = true }
    try expect(rejected, "损坏文件应报错而非冒充数据")
    _ = try store.receive(frame(quota), at: t.addingTimeInterval(4))
    try expect(try store.load()?.buckets.count == 4, "合法新帧可修复损坏")
    for badDate in ["2026-02-30T11:00:00Z", "2026-11-26T11:00:00Zjunk", "2026-11-26T24:01:00Z", "2026-11-26T11:60:00Z", "2026-11-26T11:00:00+24:00"] {
        _ = try store.receive(frame(["gemini-5h": ["remaining_fraction": 0.72, "reset_time": badDate]]), at: t)
        let invalid = bucket("gemini-5h", from: try store.load())
        try expect(invalid?.remainingFraction == 0.72 && invalid?.resetsAt == nil, "无效 RFC3339 不应正规化成其他时间：\(badDate)")
    }
    _ = try store.receive(frame(["gemini-5h": ["remaining_fraction": 0.72, "reset_time": "2026-11-26T19:00:00.125+08:00"]]), at: t)
    try expect(bucket("gemini-5h", from: try store.load())?.resetsAt == t.addingTimeInterval(7200.125), "合法偏移和小数秒")
    let one = try frame(["gemini-5h": ["remaining_fraction": 0.11]], email: a)
    let two = try frame(["3p-weekly": ["remaining_fraction": 0.22]], email: b)
    DispatchQueue.concurrentPerform(iterations: 16) { i in
        _ = try? store.receive(i % 2 == 0 ? one : two, at: t.addingTimeInterval(Double(i + 10)))
    }
    let final = try store.load()
    try expect(final?.buckets.count == 1, "并发不混合多个帧")
    try expect((final?.accountEmail == a && bucket("gemini-5h", from: final)?.remainingFraction == 0.11) || (final?.accountEmail == b && bucket("3p-weekly", from: final)?.remainingFraction == 0.22), "必须是完整的某一份观测")
}

run("AG-03b 拒绝异常快照日期与符号链接目录") {
    let store = makeStore("bad-cache")
    _ = try store.receive(frame(quota), at: t)
    var object = try config(store.snapshotURL)
    var items = object["buckets"] as! [[String: Any]]
    items[0]["resetsAt"] = 1e30; object["buckets"] = items
    try JSONSerialization.data(withJSONObject: object).write(to: store.snapshotURL)
    var refused = false
    do { _ = try store.load() } catch { refused = true }
    try expect(refused, "缓存可解码但日期不可能有效，必须拒绝")
    let destination = root.appendingPathComponent("external")
    let link = root.appendingPathComponent("owned-link")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    let linked = AntigravityStatuslineStore(snapshotURL: link.appendingPathComponent("Antigravity/cli-statusline-v1.json"))
    refused = false
    do { _ = try linked.receive(frame(quota), at: t) } catch { refused = true }
    try expect(refused && !FileManager.default.fileExists(atPath: destination.appendingPathComponent("Antigravity").path), "不能沿应用私有祖先符号链接写入外部目录")
}

run("AG-04 安装幂等、冲突保全、修复和降级防护") {
    let executable = try fakeApp("App's Test")
    let moved = try fakeApp("Moved App")
    let file = root.appendingPathComponent("cli-settings.json")
    let baseline: [String: Any] = ["theme": "dark", "permissions": ["mode": "default"], "other": ["one", "two"]]
    try JSONSerialization.data(withJSONObject: baseline).write(to: file)
    try expect(AntigravityStatuslineInstaller.status(at: file, executableURL: executable) == .notInstalled, "初始无回调")
    try AntigravityStatuslineInstaller.install(at: file, executableURL: executable)
    try expect(AntigravityStatuslineInstaller.status(at: file, executableURL: executable) == .installed, "安装状态已验证")
    let installed = try config(file)
    let line = installed["statusLine"] as? [String: Any]
    try expect(line?["type"] as? String == "command" && line?["enabled"] as? Bool == true && line?["stack_with_default"] as? Bool == true, "官方配置结构，保留内置状态行")
    try expect(installed["theme"] as? String == "dark" && installed["permissions"] as? [String: String] == ["mode":"default"] && installed["other"] as? [String] == ["one","two"], "所有无关键保留")
    let command = line?["command"] as! String
    // 自有命令不代表其余属性合法；错误类型必须原样保留，不能用修复/移除掩盖错误。
    let validBytes = try Data(contentsOf: file)
    let brokenBlocks: [[String: Any]] = [
        ["command": command, "type": "other", "enabled": true, "stack_with_default": true],
        ["command": command, "type": "command", "enabled": 1, "stack_with_default": true],
        ["command": command, "type": "command", "enabled": true, "stack_with_default": "true"],
        ["command": command, "type": "command", "padding": "unexpected"]
    ]
    for broken in brokenBlocks {
        var invalid = baseline; invalid["statusLine"] = broken
        try JSONSerialization.data(withJSONObject: invalid).write(to: file)
        let previous = try Data(contentsOf: file)
        try expect(AntigravityStatuslineInstaller.status(at: file, executableURL: executable) == .invalid, "自有块错误类型不得识别为可修复")
        var rejected = false
        do { try AntigravityStatuslineInstaller.install(at: file, executableURL: executable) } catch { rejected = true }
        try expect(rejected && (try Data(contentsOf: file)) == previous, "安装不得覆盖损坏块")
        rejected = false
        do { try AntigravityStatuslineInstaller.remove(at: file, executableURL: executable) } catch { rejected = true }
        try expect(rejected && (try Data(contentsOf: file)) == previous, "移除不得删除损坏块")
    }
    try validBytes.write(to: file)
    try expect(try execute(command).1 == AntigravityStatuslineHook.argument, "含空格和单引号的路径正确引用")
    try FileManager.default.removeItem(at: AntigravityStatuslineInstaller.markerURL(for: executable))
    let guarded = try execute(command)
    try expect(guarded.0 == 0 && guarded.1.isEmpty, "降级后无 marker 时不得执行旧程序")
    try expect(AntigravityStatuslineInstaller.status(at: file, executableURL: moved) == .needsRepair, "可识别自有旧路径")
    try AntigravityStatuslineInstaller.install(at: file, executableURL: moved)
    let before = try Data(contentsOf: file)
    try AntigravityStatuslineInstaller.install(at: file, executableURL: moved)
    try expect(try Data(contentsOf: file) == before, "重复安装幂等")
    try AntigravityStatuslineInstaller.remove(at: file, executableURL: moved)
    try expect(try config(file)["statusLine"] == nil, "移除只清自有回调")
    try expect(try config(file)["theme"] as? String == "dark", "移除保留其他字段")
    let readOnly = try Data(contentsOf: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
    var refusedReadOnly = false
    do { try AntigravityStatuslineInstaller.install(at: file, executableURL: moved) } catch { refusedReadOnly = true }
    try expect(refusedReadOnly && (try Data(contentsOf: file)) == readOnly, "禁止通过替换覆盖只读配置")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    var third = baseline; third["statusLine"] = ["type": "command", "command": "echo third-party"]
    try JSONSerialization.data(withJSONObject: third).write(to: file)
    let original = try Data(contentsOf: file)
    try expect(AntigravityStatuslineInstaller.status(at: file, executableURL: moved) == .conflict, "他人 Statusline 冲突")
    var refused = false
    do { try AntigravityStatuslineInstaller.install(at: file, executableURL: moved) } catch { refused = true }
    try expect(refused && (try Data(contentsOf: file)) == original, "不得覆盖他人配置")
    refused = false
    do { try AntigravityStatuslineInstaller.remove(at: file, executableURL: moved) } catch { refused = true }
    try expect(refused && (try Data(contentsOf: file)) == original, "不得删除他人配置")
}

print("Statusline core: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
