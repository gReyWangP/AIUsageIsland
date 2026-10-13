import Foundation

/// 公共来源只提供公告，不能改变账号额度或证明账号已收到重置。
struct OfficialResetAnnouncement: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case scheduled, reported }
    let id: String
    let resetType: String
    var phase: Phase
    let announcedAt: Date
    var scheduledFor: Date?
    let text: String
    let sourceURL: URL

    static func validSource(_ url: URL) -> Bool {
        guard url.scheme == "https", ["x.com", "twitter.com"].contains(url.host),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return false }
        let pieces = url.path.split(separator: "/")
        return pieces.count == 3 && pieces[0] == "thsottiaux" && pieces[1] == "status"
            && !pieces[2].isEmpty && pieces[2].allSatisfy(\.isNumber)
    }
    /// 仅解释明确的 tomorrow/today + 时刻 + PST，保留夏令时歧义；不猜测模糊预告。
    private var pacificTiming: (Date, Date)? {
        guard let re = try? NSRegularExpression(pattern: #"\b(tomorrow|today)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s+PST\b"#, options: [.caseInsensitive]),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func capture(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]).lowercased() } }
        guard let rawHour = capture(2).flatMap(Int.init), (1...12).contains(rawHour) else { return nil }
        let minute = capture(3).flatMap(Int.init) ?? 0
        guard (0...59).contains(minute) else { return nil }
        let hour = rawHour % 12 + (capture(4) == "pm" ? 12 : 0)
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        guard let day = pacific.date(byAdding: .day, value: capture(1) == "tomorrow" ? 1 : 0, to: announcedAt),
              let local = pacific.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return nil }
        var components = pacific.dateComponents([.year, .month, .day], from: day)
        components.hour = hour; components.minute = minute
        var standard = Calendar(identifier: .gregorian)
        standard.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        guard let literal = standard.date(from: components) else { return nil }
        return (local, literal)
    }
    var expectedAt: Date? { pacificTiming?.0 ?? scheduledFor }
    var latestExpectedAt: Date? { pacificTiming?.1 ?? scheduledFor }
    var timeDescription: String {
        guard let first = expectedAt else { return "尚未公布可确认的时间" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "M月d日 HH:mm"
        if let last = latestExpectedAt, last != first {
            return "预计北京时间 " + formatter.string(from: first) + "–" + formatter.string(from: last) + "（原帖 PST 存在夏令时歧义）"
        }
        return "预计北京时间 " + formatter.string(from: first) + "（以公告实际发放为准）"
    }
    var pushSummary: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "M月d日 HH:mm"
        let event = resetType == "banked" ? "重置券发放动态（需手动使用）"
            : phase == .scheduled ? "ChatGPT 额度重置预告" : "来源已报告 ChatGPT 额度重置"
        let reset = phase == .scheduled ? "重置时间：" + timeDescription
            : "重置时间：来源未提供确切发生时间" + (expectedAt == nil ? "" : "\n此前预告：" + timeDescription)
        let scope = text.lowercased().contains("all paid") ? "范围：所有付费账号（以原帖为准）" : "范围：请查看原帖"
        return event + "\n公告时间：" + formatter.string(from: announcedAt) + "（北京时间）\n"
            + reset + "\n重置原因：来源未明确说明\n" + scope
            + "\n请刷新账号确认实际额度。\n原帖：" + sourceURL.absoluteString
    }
    var fingerprint: String { id + ":" + phase.rawValue + ":" + String(expectedAt?.timeIntervalSince1970 ?? 0) }
    var message: UsageAlertMessage {
        let banked = resetType == "banked"
        let title = banked ? "ChatGPT · 重置券发放动态" : (phase == .scheduled ? "ChatGPT · 官方重置预告" : "ChatGPT · 官方重置动态")
        let scope = text.lowercased().contains("all paid") ? "公告面向付费账号。" : "适用套餐及范围请查看原帖。"
        let body = scope + (phase == .scheduled ? timeDescription + "。" : "有新的公开重置公告。")
            + (banked ? "重置券需要手动使用；此消息不代表已到账。" : "公告不代表你的账号额度已恢复。")
            + "来源：Codex Resets 整理的 Tibo 公告。"
        return UsageAlertMessage(metric: "official-" + fingerprint, title: title, body: body, sourceURL: sourceURL, announcement: self)
    }
}

struct OfficialResetFeed: Sendable {
    let events: [OfficialResetAnnouncement]
    let generatedAt: Date
    static func decode(_ data: Data) throws -> Self {
        struct Source: Decodable { let type: String; let author: String?; let url: URL? }
        struct Row: Decodable {
            let id: String; let reset_type: String; let announced_at: Date; let status: String?
            let scheduled_for: Date?; let text: String; let source: Source
        }
        struct Rows: Decodable { let latest_reset: Row?; let scheduled_reset: Row? }
        struct Meta: Decodable { let generated_at: Date }
        struct Root: Decodable { let data: Rows; let meta: Meta }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: value) { return date }
            f.formatOptions = [.withInternetDateTime]
            guard let date = f.date(from: value) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date")) }
            return date
        }
        let root = try decoder.decode(Root.self, from: data)
        var events: [OfficialResetAnnouncement] = []
        for (row, phase) in [(root.data.latest_reset, OfficialResetAnnouncement.Phase.reported), (root.data.scheduled_reset, .scheduled)] {
            guard let row, row.source.type == "x_post", row.source.author == "thsottiaux",
                  let url = row.source.url, OfficialResetAnnouncement.validSource(url),
                  url.lastPathComponent == row.id, ["regular", "banked"].contains(row.reset_type),
                  !row.text.isEmpty, row.text.count <= 20_000 else { continue }
            if phase == .scheduled && row.status != "scheduled" { continue }
            if phase == .reported && row.status != nil && row.status != "executed" { continue }
            events.append(.init(id: row.id, resetType: row.reset_type, phase: phase, announcedAt: row.announced_at,
                                scheduledFor: row.scheduled_for, text: row.text, sourceURL: url))
        }
        return Self(events: events, generatedAt: root.meta.generated_at)
    }
}

struct OfficialResetLedger: Codable {
    private var seen: [String: Date] = [:]
    private var initialized = false
    mutating func observe(_ events: [OfficialResetAnnouncement], now: Date, allowed: Bool) -> [OfficialResetAnnouncement] {
        let wasInitialized = initialized
        initialized = true
        var notices: [OfficialResetAnnouncement] = []
        for event in events.sorted(by: { $0.announcedAt < $1.announcedAt }) {
            let fresh = event.announcedAt <= now.addingTimeInterval(300) && now.timeIntervalSince(event.announcedAt) <= 86400
            let upcoming = event.latestExpectedAt.map { $0 > now } ?? true
            let eligible = event.phase == .scheduled && event.latestExpectedAt != nil
                ? event.announcedAt <= now.addingTimeInterval(300) && upcoming : fresh
            if seen[event.fingerprint] == nil && allowed && eligible
                && (event.phase == .scheduled ? upcoming : wasInitialized) { notices.append(event) }
            // 关闭或静默时也记录，避免恢复开关后补发旧消息。
            seen[event.fingerprint] = now
        }
        if seen.count > 128 { seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(128).map { ($0.key, $0.value) }) }
        return notices
    }
}
