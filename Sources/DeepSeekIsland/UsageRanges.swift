import Foundation

struct UsageRange: Sendable {
    let start: Date
    let end: Date

    func contains(_ unixSeconds: Int64) -> Bool {
        let instant = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        return start <= instant && instant < end
    }

    func url(kind: String, timezoneOffset: Int) -> URL? {
        guard kind == "amount" || kind == "cost" else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "platform.deepseek.com"
        components.path = "/api/v0/usage/by_api_key/\(kind)"
        components.queryItems = [
            URLQueryItem(name: "start", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end", value: String(Int(end.timeIntervalSince1970))),
            URLQueryItem(name: "tz", value: String(timezoneOffset))
        ]
        return components.url
    }
}

struct UsageRanges: Sendable {
    let today: UsageRange
    let sevenDays: UsageRange
    let month: UsageRange
    let thirtyDays: UsageRange
    let timezoneOffset: Int

    var queryRange: UsageRange {
        UsageRange(start: min(thirtyDays.start, month.start), end: today.end)
    }

    init(now: Date, calendar: Calendar) {
        let startToday = calendar.startOfDay(for: now)
        let endToday = calendar.date(byAdding: .day, value: 1, to: startToday)!
        let startSevenDays = calendar.date(byAdding: .day, value: -6, to: startToday)!
        let startMonth = calendar.dateInterval(of: .month, for: now)!.start
        let endMonth = calendar.date(byAdding: .month, value: 1, to: startMonth)!
        thirtyDays = UsageRange(start: calendar.date(byAdding: .day, value: -29, to: startToday)!, end: endToday)
        today = UsageRange(start: startToday, end: endToday)
        sevenDays = UsageRange(start: startSevenDays, end: endToday)
        month = UsageRange(start: startMonth, end: endMonth)
        timezoneOffset = calendar.timeZone.secondsFromGMT(for: now)
    }
}
