// 固定合成缓存、独立手算价格和文件不变量；不读取实际桌面会话、账号或插件数据。
import Foundation
import Darwin

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
let zone = TimeZone(identifier: "Asia/Shanghai")!
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = zone
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let plain = ISO8601DateFormatter()
/// 将测试 ISO 时间转为真正 Unix 毫秒，保留小数精度。
func ms(_ text: String) -> Double {
    return (iso.date(from: text) ?? plain.date(from: text)!).timeIntervalSince1970 * 1000
}
let now = plain.date(from: "2026-12-01T01:00:00Z")!
struct Failure: LocalizedError { let message: String; var errorDescription: String? { return message } }
/// 失败只报告合成断言原因，不打印源文件。
func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !condition() { throw Failure(message: reason) }
}
/// 固定输入含不允许进入显示模型的无关字段。
func event(_ id: String, _ date: String, _ model: String, _ input: Any, _ cache: Any, _ output: Any) -> [String: Any] {
    return ["id": id, "timestampMs": ms(date), "model": model, "inputTokens": input, "cacheReadTokens": cache, "outputTokens": output,
            "thinkingTokens": 9999999, "content": "SYNTHETIC_DO_NOT_PERSIST_OR_DISPLAY", "error": "SYNTHETIC_PRIVATE_DETAIL"]
}
let carbon: [String: Any] = ["model":"gemini-4-carbon","input":2,"cache":0.1,"output":10,"until":"2026-12-01","next":["input":4,"cache":0.2,"output":20]]
let neon: [String: Any] = ["model":"gemini-4-neon","input":3,"cache":0.15,"output":15]
let catalog: [String: Any] = ["checkedAt":"2026-11-27T02:00:00.125Z","rates":[carbon,neon]]
let a = event("a", "2026-11-30T23:59:59.125Z", "Gemini 4 Carbon (High)", 1000000, 2000000, 100000)
let b = event("b", "2026-12-01T00:01:00.250Z", "Gemini 4 Carbon (Medium)", 2000000, 1000000, 200000)
let c = event("c", "2026-11-30T14:00:00Z", "Gemini 4 Neon (XHigh)", 3000000, 4000000, 300000)
/// 建立每条测试独立目录与真实源文件，以便验证 I/O 行为。
func fixture(_ name: String, rows: [[String: Any]], prices: Any? = catalog) throws -> (PowertoolsUsageReader, URL, URL) {
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let usage = dir.appendingPathComponent("usage-history-cache.json")
    let price = dir.appendingPathComponent("pricing.json")
    try JSONSerialization.data(withJSONObject: rows).write(to: usage)
    if let prices = prices { try JSONSerialization.data(withJSONObject: prices).write(to: price) }
    return (PowertoolsUsageReader(directoryURL: dir), usage, price)
}
var passed = 0, failed = 0
/// 执行单组独立断言并保留失败计数。
func run(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS: \(name)") }
    catch { failed += 1; fputs("FAIL: \(name): \(error.localizedDescription)\n", stderr) }
}
/// 比较独立手算的美元金额，未知不能被当成零。
func near(_ actual: Double?, _ expected: Double) -> Bool {
    return actual.map { abs($0 - expected) < 0.0000001 } ?? false
}
run("PT-01 小数毫秒、UTC 变价、上海日历和重复记录") {
    let (reader, usage, price) = try fixture("base", rows: [a,a,b,c])
    let oldUsage = try Data(contentsOf: usage), oldPrice = try Data(contentsOf: price)
    let result = try reader.load(now: now, calendar: calendar)
    let day = result.summary(for: .today, now: now)
    let week = result.summary(for: .sevenDays, now: now)
    let month = result.summary(for: .month, now: now)
    try expect(result.sourceRecordCount == 4 && result.duplicateRecordCount == 1 && result.rejectedRecordCount == 0, "记录计数和去重")
    try expect(day.totals.recordCount == 2 && day.totals.newInputTokens == 3000000 && day.totals.cachedInputTokens == 3000000 && day.totals.outputTokens == 300000, "今日三桶")
    try expect(day.totals.totalTokens == 6300000 && near(day.totals.estimatedCostUSD, 15.40), "今日 Token 与独立手算金额")
    try expect(near(day.totals.cacheHitFraction, 0.5) && day.totals.pricedRecordCount == 2, "以总输入为分母")
    try expect(month.totals == day.totals, "月边界按上海日历")
    try expect(week.totals.recordCount == 3 && week.totals.totalTokens == 13600000 && near(week.totals.estimatedCostUSD, 29.50), "7天合计")
    try expect(near(week.totals.cacheHitFraction, 7.0/13.0), "命中率不得平均各行百分比")
    try expect(week.models.first(where: { $0.id == "gemini-4-carbon" })?.totals.totalTokens == 6300000, "同模型档位归并")
    try expect(week.models.first(where: { $0.id == "gemini-4-neon" })?.totals.totalTokens == 7300000, "按实际模型归并")
    try expect(result.pricingCheckedAt == iso.date(from: "2026-11-27T02:00:00.125Z"), "价格日期不被检查时间覆盖")
    try expect(result.observedStart == plain.date(from: "2026-11-30T14:00:00Z") && result.observedEnd == iso.date(from: "2026-12-01T00:01:00.250Z"), "原事件覆盖边界")
    try expect(try Data(contentsOf: usage) == oldUsage && Data(contentsOf: price) == oldPrice, "源文件不应被写入")
}
run("PT-02 未知模型、真实零、冲突与非法桶") {
    let unknown = event("u", "2026-12-01T00:03:00Z", "Orchestrator (High)", 400,500,600)
    let zero = event("z", "2026-12-01T00:04:00Z", "Gemini 4 Neon",0,0,0)
    let x1 = event("x", "2026-12-01T00:05:00Z", "Gemini 4 Neon",1,2,3)
    let x2 = event("x", "2026-12-01T00:05:00Z", "Gemini 4 Neon",2,2,3)
    var missing = event("missing", "2026-12-01T00:06:00Z", "Gemini 4 Neon",1,2,3); missing.removeValue(forKey:"cacheReadTokens")
    let bad = event("bool", "2026-12-01T00:07:00Z", "Gemini 4 Neon",true,2,3)
    let huge = event("huge", "2026-12-01T00:08:00Z", "Gemini 4 Neon",9007199254740991 as Int64,2,3)
    let (reader, _, _) = try fixture("partial", rows:[unknown,zero,x1,x2,missing,bad,huge])
    let result = try reader.load(now: now, calendar: calendar)
    let totals = result.summary(for:.today, now:now).totals
    try expect(result.conflictingIDCount == 1 && result.rejectedRecordCount == 3, "冲突整组与坏行分开")
    try expect(totals.recordCount == 2 && totals.totalTokens == 1500, "未知模型可计Token、真实零有效")
    try expect(totals.pricedRecordCount == 1 && near(totals.estimatedCostUSD,0), "部分已计零与全部未知不同")
    let unknownModel = result.summary(for:.today,now:now).models.first(where: {$0.id == "unknown"})
    try expect(unknownModel?.totals.estimatedCostUSD == nil && unknownModel?.totals.totalTokens == 1500, "不得把 Orchestrator 猜成 Carbon")
    let nextDay = now.addingTimeInterval(86400)
    try expect(result.summary(for:.today,now:nextDay).totals.recordCount == 0, "跨日不把昨天当今天")
}
run("PT-02 同一 ID 的坏行与未来事件不会制造可靠总量") {
    var badDuplicate = a
    badDuplicate.removeValue(forKey: "outputTokens")
    let future = event("future", "2026-12-01T01:00:01Z", "Gemini 4 Neon", 10, 20, 30)
    let (reader, _, _) = try fixture("uncertain", rows: [a, badDuplicate, future, b])
    let result = try reader.load(now: now, calendar: calendar)
    try expect(result.conflictingIDCount == 1 && result.rejectedRecordCount == 2, "不完整同ID记录形成冲突，未来事件不可计")
    try expect(result.summary(for: .retained, now: now).totals.totalTokens == 3200000, "仅计已发生且无冲突的b")
    let (reverse, _, _) = try fixture("uncertain-reverse", rows: [badDuplicate, a, future, b])
    try expect(try reverse.load(now: now, calendar: calendar).summary(for: .retained, now: now).totals.totalTokens == 3200000, "坏行顺序不能改变结果")
}
run("PT-02 未识别模型不能通过统一显示名错误去重") {
    let u1 = event("u", "2026-12-01T00:05:00Z", "Orchestrator A", 2, 3, 4)
    let u2 = event("u", "2026-12-01T00:05:00Z", "Orchestrator B", 2, 3, 4)
    let (reader, _, _) = try fixture("unknown-conflict", rows: [u1, u2])
    let result = try reader.load(now: now, calendar: calendar)
    try expect(result.conflictingIDCount == 1 && result.summary(for: .retained, now: now).totals.recordCount == 0, "不同未知模型同ID按冲突剔除")
    let (reverse, _, _) = try fixture("unknown-conflict-reverse", rows: [u2, u1])
    try expect(try reverse.load(now: now, calendar: calendar).summary(for: .retained, now: now).totals.totalTokens == 0, "顺序无关")
    let (repeatReader, _, _) = try fixture("unknown-identical", rows: [u1, u1])
    let repeated = try repeatReader.load(now: now, calendar: calendar)
    try expect(repeated.duplicateRecordCount == 1 && repeated.summary(for: .retained, now: now).totals.totalTokens == 9, "相同未知模型仍可计数但不猜价")
}
run("PT-02 价格缺失、坏价和冲突价不吞 Token") {
    let (missing,_,_) = try fixture("missing-price", rows:[a],prices:nil)
    let result = try missing.load(now:now,calendar:calendar)
    try expect(result.summary(for:.retained,now:now).totals.totalTokens == 3100000, "缺价仍显示用量")
    try expect(result.summary(for:.retained,now:now).totals.estimatedCostUSD == nil && result.pricingIssue != nil, "无有效价格保持未知")
    var broken = carbon; broken["cache"] = true
    let (invalid,_,_) = try fixture("invalid-price", rows:[a], prices:["rates":[broken]])
    try expect(try invalid.load(now:now,calendar:calendar).summary(for:.retained,now:now).totals.pricedRecordCount == 0, "Bool 不是费率")
    var other = carbon; other["input"] = 99
    let (conflict,_,_) = try fixture("conflict-price", rows:[a,c],prices:["rates":[carbon,other,neon]])
    let total = try conflict.load(now:now,calendar:calendar).summary(for:.retained,now:now).totals
    try expect(total.pricedRecordCount == 1 && near(total.estimatedCostUSD,14.1), "冲突价不任选一条")
}
run("PT-02 空/损坏与超限、异常链接") {
    let (reader,usage,_) = try fixture("empty", rows:[])
    let empty = try reader.load(now:now,calendar:calendar)
    try expect(empty.summary(for:.today,now:now).totals.recordCount == 0 && empty.summary(for:.today,now:now).totals.estimatedCostUSD == nil, "空源不编造已计价格")
    try Data("{broken".utf8).write(to:usage)
    var refused = false
    do { _ = try reader.load(now:now,calendar:calendar) } catch { refused = true }
    try expect(refused,"损坏源必须报错")
    try Data(repeating:32,count:16*1024*1024+1).write(to:usage)
    refused = false
    do { _ = try reader.load(now:now,calendar:calendar) } catch { refused = true }
    try expect(refused,"超过明确读取上限")
    let (external, validUsage, _) = try fixture("safe-data", rows: [a])
    let linkDir = root.appendingPathComponent("link",isDirectory:true);try FileManager.default.createDirectory(at:linkDir,withIntermediateDirectories:true)
    // 指向确实可读的数据；误追链接的实现不能靠先前的超限错误蒙混过关。
    try FileManager.default.createSymbolicLink(at:linkDir.appendingPathComponent("usage-history-cache.json"),withDestinationURL:validUsage)
    refused = false
    do { _ = try PowertoolsUsageReader(directoryURL:linkDir).load(now:now,calendar:calendar) } catch { refused = true }
    try expect(refused,"不跟随源文件链接")
    // 符号链接即便位于四层以上的祖先也不能把读取范围改为外部目录。
    let deep = root.appendingPathComponent("target/one/two/three/four", isDirectory: true)
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    try Data(contentsOf: external.directoryURL.appendingPathComponent("usage-history-cache.json")).write(to: deep.appendingPathComponent("usage-history-cache.json"))
    let ancestorLink = root.appendingPathComponent("ancestor-link")
    try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: root.appendingPathComponent("target"))
    refused = false
    do { _ = try PowertoolsUsageReader(directoryURL: ancestorLink.appendingPathComponent("one/two/three/four")).load(now:now,calendar:calendar) } catch { refused = true }
    try expect(refused,"祖先链接同样必须拒绝")
}
print("Powertools core: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
