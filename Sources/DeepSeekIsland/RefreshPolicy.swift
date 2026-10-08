import Foundation

struct RefreshPolicy {
    private(set) var failures = 0
    private(set) var nextAttempt: Date?
    private var needsAuthorization = false
    private var rateLimitedUntil: Date?
    var cooldownUntil: Date? { rateLimitedUntil }
    func canAttempt(at now: Date = .now, manual: Bool = false) -> Bool {
        if let deadline = rateLimitedUntil, now < deadline { return false }
        if manual { return true }
        return !needsAuthorization && (nextAttempt.map { now >= $0 } ?? true)
    }
    mutating func record(_ failure: UsageRefreshFailure?, at now: Date = .now) {
        guard failure != .cancelled else { return }
        guard let failure else { self = Self(); return }
        failures = min(failures + 1, 8)
        if failure == .authorization || failure == .credentialPersistence || failure == .noQuota {
            needsAuthorization = true; nextAttempt = nil; return
        }
        var delay = min(1800, 60 * pow(2, Double(failures - 1)))
        if case .rateLimited(let until) = failure {
            if let until { delay = max(delay, until.timeIntervalSince(now)) }
            rateLimitedUntil = now.addingTimeInterval(delay)
        } else if failure == .http(429) { rateLimitedUntil = now.addingTimeInterval(delay) }
        nextAttempt = now.addingTimeInterval(delay)
    }
    var explanation: String? {
        if needsAuthorization { return "请重新验证账号后刷新。" }
        return nextAttempt.map { "下次自动尝试：" + $0.formatted(date: .omitted, time: .shortened) }
    }
    static func balanceFailure(primary: UsageRefreshFailure?, auxiliary: UsageRefreshFailure?) -> UsageRefreshFailure? {
        if let primary { return primary }
        // 辅助用量接口的授权规则不能阻断余额；限流仍须遵守。
        if case .rateLimited = auxiliary { return auxiliary }
        if auxiliary == .http(429) { return auxiliary }
        return nil
    }
    static func retryDate(_ header: String?, at now: Date = .now) -> Date? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(min(86400, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { min(now.addingTimeInterval(86400), max(now, $0)) }
    }
}

actor PlatformRequestLimiter {
    static let shared = PlatformRequestLimiter(limit: 2)
    private let limit: Int
    private var counts: [UsagePlatform: Int] = [:]
    private var cooldown: [UsagePlatform: Date] = [:]
    init(limit: Int) { self.limit = max(1, limit) }
    func acquire(_ platform: UsagePlatform, at now: Date = .now) -> Bool {
        guard cooldown[platform].map({ now >= $0 }) ?? true, counts[platform, default: 0] < limit else { return false }
        counts[platform, default: 0] += 1; return true
    }
    func release(_ platform: UsagePlatform) { counts[platform] = max(0, counts[platform, default: 0] - 1) }
    func pause(_ platform: UsagePlatform, until: Date) { cooldown[platform] = max(cooldown[platform] ?? .distantPast, until) }
}
