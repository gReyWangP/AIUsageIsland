import Combine
import Foundation

enum UsageAnalysisSource: String, Codable, Sendable {
    case chatGPT, deepSeek, zhipu
    var label: String { switch self { case .chatGPT: "ChatGPT 官方 Codex 日统计"; case .deepSeek: "DeepSeek 官方用量接口"; case .zhipu: "智谱官方模型用量" } }
}
struct DailyUsageBucket: Codable, Identifiable, Equatable, Sendable {
    var id: String { day }
    let day: String
    let tokens: Int64
    var cachedInput: Int64? = nil
    var uncachedInput: Int64? = nil
    var output: Int64? = nil
    var cost: Decimal? = nil
    var isPartial = false
    var isCached: Bool? = nil
    var lastReturnedAt: Date? = nil
    var date: Date { UsageAnalysisMath.date(day) ?? .distantPast }
}
struct UsageAnalysisSnapshot: Codable, Sendable {
    let source: UsageAnalysisSource
    var buckets: [DailyUsageBucket]
    var updatedAt: Date = .now
    var currency: String? = nil
    var timezone: String = "Asia/Shanghai"
}
enum UsageAnalysisError: LocalizedError {
    case unavailable, invalidResponse
    var errorDescription: String? { switch self { case .unavailable: "官方尚未返回日用量统计"; case .invalidResponse: "官方用量格式暂不支持，已有历史仍保留" } }
}
enum UsageAnalysisMath {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT:0)!
        return calendar
    }()
    static func date(_ day: String) -> Date? {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              [0,1,2,3,5,6,8,9].allSatisfy({(48...57).contains(bytes[$0])}) else { return nil }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) {$0*10+Int(bytes[$1]-48)} }
        let year=number(0..<4), month=number(5..<7), dayNumber=number(8..<10)
        guard year > 0, (1...12).contains(month), (1...31).contains(dayNumber),
              let value=utcCalendar.date(from:DateComponents(year:year,month:month,day:dayNumber)) else {return nil}
        let actual=utcCalendar.dateComponents([.year,.month,.day],from:value)
        guard actual.year == year, actual.month == month, actual.day == dayNumber else {return nil}
        return value
    }
    static func day(_ now: Date, timezone: String = "Asia/Shanghai") -> String {
        var calendar=utcCalendar
        calendar.timeZone=TimeZone(identifier:timezone) ?? utcCalendar.timeZone
        let parts=calendar.dateComponents([.year,.month,.day],from:now)
        return String(format:"%04d-%02d-%02d",parts.year!,parts.month!,parts.day!)
    }
    static func sum(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values { guard value >= 0 else { return nil }; let (n, overflow) = total.addingReportingOverflow(value); guard !overflow else { return nil }; total = n }; return total
    }
    static func cacheRate(_ buckets: [DailyUsageBucket]) -> Double? {
        guard !buckets.isEmpty, buckets.allSatisfy({ $0.cachedInput != nil && $0.uncachedInput != nil }),
              let hit = sum(buckets.compactMap(\.cachedInput)), let miss = sum(buckets.compactMap(\.uncachedInput)),
              let input = sum([hit, miss]), input > 0 else { return nil }
        return Double(hit) / Double(input) * 100
    }
    static func averages(_ buckets: [DailyUsageBucket]) -> [DailyUsageBucket] {
        let sorted = buckets.sorted { $0.day < $1.day }; guard sorted.count >= 7 else { return [] }
        return (6..<sorted.count).compactMap { index in
            let window = Array(sorted[(index-6)...index])
            guard !window.contains(where: \.isPartial), window.last!.date.timeIntervalSince(window.first!.date) == 6 * 86400,
                  let total = sum(window.map(\.tokens)) else { return nil }
            return DailyUsageBucket(day: sorted[index].day, tokens: total / 7)
        }
    }
    static func recent(_ snapshot: UsageAnalysisSnapshot?, days: Int, now: Date = .now) -> [DailyUsageBucket] {
        guard let snapshot, let today = date(day(now, timezone: snapshot.timezone)) else { return [] }
        let start = today.addingTimeInterval(-Double(days - 1) * 86400)
        return snapshot.buckets.filter { $0.date >= start && $0.date <= today }.sorted { $0.day < $1.day }
    }
    static func validate(_ buckets: [DailyUsageBucket]) -> Bool {
        guard buckets.count <= 400, Set(buckets.map(\.day)).count == buckets.count else { return false }
        return buckets.allSatisfy { b in
            guard date(b.day) != nil, b.tokens >= 0, [b.cachedInput,b.uncachedInput,b.output].compactMap({$0}).allSatisfy({$0 >= 0}), b.cost.map({!$0.isNaN && $0 >= 0}) ?? true else { return false }
            if let hit = b.cachedInput, let miss = b.uncachedInput, let output = b.output { return sum([hit,miss,output]) == b.tokens }; return true
        }
    }
}
enum UsageAnalysisParser {
    static func chatGPT(_ data: Data, now: Date = .now) throws -> UsageAnalysisSnapshot {
        struct Profile: Decodable { struct Stats: Decodable { struct Bucket: Decodable { let start_date: String; let tokens: Int64 }; let daily_usage_buckets: [Bucket]? }; let stats: Stats }
        guard data.count <= 2_000_000, let profile = try? JSONDecoder().decode(Profile.self, from: data), let raw = profile.stats.daily_usage_buckets else { throw UsageAnalysisError.unavailable }
        let today = UsageAnalysisMath.day(now, timezone: "UTC")
        guard raw.count <= 10_000, Set(raw.map(\.start_date)).count == raw.count,
              raw.allSatisfy({ UsageAnalysisMath.date($0.start_date) != nil && $0.tokens >= 0 && $0.start_date <= today }) else { throw UsageAnalysisError.invalidResponse }
        let start=UsageAnalysisMath.date(today)!.addingTimeInterval(-89*86400)
        let buckets = raw.filter { UsageAnalysisMath.date($0.start_date)! >= start }.map { DailyUsageBucket(day: $0.start_date, tokens: $0.tokens, isPartial: $0.start_date >= today) }
        guard UsageAnalysisMath.validate(buckets) else { throw UsageAnalysisError.invalidResponse }
        return .init(source: .chatGPT, buckets: buckets.sorted {$0.day < $1.day}, updatedAt: now, timezone: "UTC")
    }
    static func zhipu(_ data: Data, now: Date = .now) throws -> UsageAnalysisSnapshot {
        guard data.count <= 2_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["success"] as? Bool != false,
              let body = root["data"] as? [String: Any], (root["code"] as? Int).map({$0 == 0 || $0 == 200}) ?? true else { throw UsageAnalysisError.invalidResponse }
        let payload = body["modelUsage"] as? [String: Any] ?? body
        guard let times = (payload["xTime"] ?? payload["x_time"]) as? [String], times.count <= 1000 else { throw UsageAnalysisError.unavailable }
        var values: [Int64] = []
        if let total = payload["tokensUsage"] as? [Any] { values = try numbers(total) }
        else if let models = payload["modelDataList"] as? [[String: Any]], !models.isEmpty {
            values = Array(repeating: 0, count: times.count)
            for model in models {
                guard let raw = (model["totalTokensUsage"] ?? model["tokensUsage"]) as? [Any] else { throw UsageAnalysisError.invalidResponse }
                let numbers = try numbers(raw); guard numbers.count == times.count else { throw UsageAnalysisError.invalidResponse }
                for index in values.indices { guard let n = UsageAnalysisMath.sum([values[index],numbers[index]]) else { throw UsageAnalysisError.invalidResponse }; values[index] = n }
            }
        } else if times.isEmpty { return .init(source: .zhipu, buckets: [], updatedAt: now) }
        else { throw UsageAnalysisError.unavailable }
        guard values.count == times.count, Set(times).count == times.count else { throw UsageAnalysisError.invalidResponse }
        var totals: [String: Int64] = [:], slots: [String: Set<String>] = [:], daily: Set<String> = []
        for (index, time) in times.enumerated() {
            let day = String(time.prefix(10)); guard UsageAnalysisMath.date(day) != nil else { throw UsageAnalysisError.invalidResponse }
            if time.count == 10 { daily.insert(day) }
            else { guard time.range(of:#"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?$"#,options:.regularExpression) != nil,
                Int(time.dropFirst(11).prefix(2)).map({(0...23).contains($0)}) == true,
                Int(time.dropFirst(14).prefix(2)).map({(0...59).contains($0)}) == true else { throw UsageAnalysisError.invalidResponse }; slots[day, default: []].insert(String(time.dropFirst(11).prefix(2))) }
            guard let total = UsageAnalysisMath.sum([totals[day, default:0], values[index]]) else { throw UsageAnalysisError.invalidResponse }; totals[day] = total
        }
        let today = UsageAnalysisMath.day(now)
        let buckets = totals.keys.sorted().map { DailyUsageBucket(day:$0, tokens:totals[$0]!, isPartial:$0 >= today || (!daily.contains($0) && slots[$0]?.count != 24)) }
        guard UsageAnalysisMath.validate(buckets), buckets.allSatisfy({$0.day <= today}) else { throw UsageAnalysisError.invalidResponse }
        return .init(source:.zhipu,buckets:buckets,updatedAt:now)
    }
    private static func numbers(_ raw: [Any]) throws -> [Int64] {
        try raw.map { value in
            if let number=value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { throw UsageAnalysisError.invalidResponse }
            guard !(value is NSNull), let text = (value as? String) ?? (value as? NSNumber)?.stringValue, let number = Int64(text), number >= 0 else { throw UsageAnalysisError.invalidResponse }; return number
        }
    }
}
struct UsageAnalysisPeriod {
    let buckets: [DailyUsageBucket]
    let averages: [DailyUsageBucket]
    let segments: [String:String]
    let dateDomain: ClosedRange<Date>
    let totalTokens: Int64?
    let completeAverage: Int64?
    let cacheRate: Double?
    let cost: Decimal?
    init(snapshot: UsageAnalysisSnapshot?, days: Int, now: Date) {
        buckets=UsageAnalysisMath.recent(snapshot,days:days,now:now)
        let visible=Set(buckets.map(\.day))
        averages=UsageAnalysisMath.averages(snapshot?.buckets ?? []).filter {visible.contains($0.day)}
        var segments: [String:String]=[:], segment=0, previous:Date?
        for b in averages {
            if let previous, b.date.timeIntervalSince(previous) != 86400 {segment+=1}
            segments[b.day]=String(segment);previous=b.date
        }
        self.segments=segments
        let today=UsageAnalysisMath.date(UsageAnalysisMath.day(now,timezone:snapshot?.timezone ?? "Asia/Shanghai"))!
        dateDomain=today.addingTimeInterval(-Double(days-1)*86400)...today.addingTimeInterval(86400)
        totalTokens=buckets.isEmpty ? nil : UsageAnalysisMath.sum(buckets.map(\.tokens))
        let complete=buckets.filter {!$0.isPartial}
        completeAverage=complete.isEmpty ? nil : UsageAnalysisMath.sum(complete.map(\.tokens)).map {$0/Int64(complete.count)}
        cacheRate=UsageAnalysisMath.cacheRate(buckets)
        cost = !buckets.isEmpty && buckets.allSatisfy({$0.cost != nil}) ? buckets.reduce(.zero) {$0+($1.cost ?? .zero)} : nil
    }
}
@MainActor
final class UsageAnalysisStore: ObservableObject {
    @Published private(set) var snapshot: UsageAnalysisSnapshot? { didSet { invalidatePresentation() } }
    @Published private(set) var error: String?
    @Published private(set) var refreshFailure: UsageRefreshFailure?
    @Published var isLoading = false
    private var periods: [Int:UsageAnalysisPeriod] = [:]
    private var preparedDay: String?
    private var overviews: [UsagePlatform:UsageAnalysisOverview] = [:]
    private func invalidatePresentation() { periods.removeAll(); overviews.removeAll(); preparedDay=nil }
    func period(days: Int, now: Date = .now) -> UsageAnalysisPeriod {
        let day=UsageAnalysisMath.day(now,timezone:snapshot?.timezone ?? "Asia/Shanghai")
        if preparedDay != day {
            periods=[7:UsageAnalysisPeriod(snapshot:snapshot,days:7,now:now),30:UsageAnalysisPeriod(snapshot:snapshot,days:30,now:now)]
            preparedDay=day;overviews.removeAll()
        }
        if let value=periods[days] {return value}
        let value=UsageAnalysisPeriod(snapshot:snapshot,days:days,now:now);periods[days]=value;return value
    }
    func overview(platform: UsagePlatform) -> UsageAnalysisOverview {
        _ = period(days:7)
        if let value=overviews[platform] {return value}
        let value=UsageAnalysisOverview.build(self,platform:platform);overviews[platform]=value;return value
    }
    @Published private(set) var persistenceError: String?
    @Published private(set) var isLoadingHistory = true
    private let storage: HistoryPersistence
    private var loadTask: Task<Void, Never>?
    private var revision = 0
    private var valid = true
    private var sealed = false
    init(directory: URL, storage: HistoryPersistence? = nil) {
        self.storage = storage ?? HistoryPersistence(directory: directory)
        let read = self.storage.beginLoad(UsageAnalysisSnapshot.self, file: "usage-analysis.json")
        loadTask = Task { [weak self] in
            let value = await read.value
            guard let self, self.valid else { return }
            if let value, UsageAnalysisMath.validate(value.buckets) {
                if self.revision == 0 { self.snapshot = value }
                else if var current = self.snapshot, current.source == value.source,
                        current.currency == value.currency, current.timezone == value.timezone {
                    var merged = Dictionary(uniqueKeysWithValues: value.buckets.map { bucket in
                        var cached = bucket; cached.isCached = true; cached.lastReturnedAt = cached.lastReturnedAt ?? value.updatedAt
                        return (cached.day, cached)
                    })
                    current.buckets.forEach { merged[$0.day] = $0 }
                    let today = UsageAnalysisMath.date(UsageAnalysisMath.day(current.updatedAt, timezone: current.timezone)) ?? current.updatedAt
                    current.buckets = merged.values.filter { $0.date >= today.addingTimeInterval(-89 * 86400) && $0.date <= today }.sorted { $0.day < $1.day }
                    self.snapshot = current
                    self.persist(current)
                }
            }
            self.isLoadingHistory = false
        }
    }
    func stopAcceptingUpdates() { sealed = true }
    func waitUntilLoaded() async { await loadTask?.value }
    func invalidate() { valid = false; loadTask?.cancel(); storage.invalidate() }
    func accept(_ value: UsageAnalysisSnapshot) {
        guard valid, !sealed else { return }
        guard UsageAnalysisMath.validate(value.buckets) else { fail(UsageAnalysisError.invalidResponse.localizedDescription, failure: .invalidResponse); return }
        if value.buckets.isEmpty, snapshot?.buckets.isEmpty == false { fail("官方未返回日统计，已有历史仍保留"); return }
        revision += 1
        var merged: [String:DailyUsageBucket] = [:]
        if let previous=snapshot, previous.source == value.source, previous.currency == value.currency, previous.timezone == value.timezone {
            for var b in previous.buckets { b.isCached=true; b.lastReturnedAt = b.lastReturnedAt ?? previous.updatedAt; merged[b.day]=b }
        }
        for var b in value.buckets { b.isCached=false; b.lastReturnedAt=value.updatedAt; merged[b.day]=b }
        var saved=value
        let today=UsageAnalysisMath.date(UsageAnalysisMath.day(value.updatedAt,timezone:value.timezone)) ?? value.updatedAt
        saved.buckets=merged.values.filter {$0.date >= today.addingTimeInterval(-89*86400) && $0.date <= today}.sorted {$0.day < $1.day}
        snapshot = saved; error = nil; refreshFailure = nil
        persist(saved)
    }
    private func persist(_ value: UsageAnalysisSnapshot) {
        let savedRevision = revision
        storage.save(value, file: "usage-analysis.json") { [weak self] success in
            guard let self, self.valid, self.revision == savedRevision else { return }
            self.persistenceError = success ? nil : "无法保存用量历史，当前数据暂存在内存中"
            self.overviews.removeAll()
        }
    }
    func fail(_ message: String, failure: UsageRefreshFailure = .unknown) {
        guard failure != .cancelled else { return }
        overviews.removeAll(); error = message; refreshFailure = failure
    }
    func clear() { invalidate(); snapshot = nil; error = nil; refreshFailure = nil; persistenceError = nil; storage.invalidate(removingFiles: true) }
    func freshness(connected: Bool, networkAvailable: Bool, at now: Date = .now) -> DataFreshness {
        DataFreshness.resolve(connected: connected, loading: isLoading, lastSuccess: snapshot?.updatedAt,
                              networkAvailable: networkAvailable, failure: refreshFailure,
                              legacyReason: nil, platform: snapshot?.source.platform ?? .chatGPT, at: now)
    }
}

private extension UsageAnalysisSource {
    var platform: UsagePlatform {
        switch self { case .deepSeek: .deepSeek; case .chatGPT: .chatGPT; case .zhipu: .zhipu }
    }
}
