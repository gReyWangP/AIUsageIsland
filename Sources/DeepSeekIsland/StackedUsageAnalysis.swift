import Foundation

struct StackedUsageInput {
    let account: AccountReference
    let snapshot: UsageAnalysisSnapshot?
}

struct StackedUsageSegment: Identifiable {
    var id: AccountReference { account }
    let account: AccountReference
    var platform: UsagePlatform { account.platform }
    let tokens: Int64
    let lower: Int64
    let upper: Int64
    let isPartial: Bool
    let isCached: Bool
    let returnedAccounts: Int
    let expectedAccounts: Int
}

struct StackedUsageDay: Identifiable {
    var id: String { day }
    let day: String
    var date: Date { UsageAnalysisMath.date(day)! }
    /// Sum of the returned accounts, even when other accounts have no data.
    /// Nil means no returned data, or a total that cannot be represented safely.
    let totalTokens: Int64?
    let segments: [StackedUsageSegment]
    let missingAccounts: Int
    let isPartial: Bool
    let isCached: Bool
    let hasOverflow: Bool
}

struct StackedUsagePeriod {
    let platforms: [UsagePlatform]
    let buckets: [StackedUsageDay]
    let dateDomain: ClosedRange<Date>
    let totalTokens: Int64?
    let completeDays: Int
    let hasOverflow: Bool

    init(inputs: [StackedUsageInput], days: Int, now: Date = .now) {
        // A duplicate account must not count twice; prefer its latest snapshot.
        var unique: [AccountReference: StackedUsageInput] = [:]
        for input in inputs {
            if let existing = unique[input.account],
               existing.snapshot?.updatedAt ?? .distantPast >= input.snapshot?.updatedAt ?? .distantPast {
                continue
            }
            unique[input.account] = input
        }
        platforms = UsagePlatform.allCases.filter { platform in unique.keys.contains { $0.platform == platform } }
        let localToday = UsageAnalysisMath.day(now, timezone: TimeZone.current.identifier)
        let latestDay = unique.values.compactMap { input in
            input.snapshot.map { UsageAnalysisMath.day(now, timezone: $0.timezone) }
        }.reduce(localToday, max)
        let today = UsageAnalysisMath.date(latestDay)!
        let dayCount = max(1, min(days, 400))
        let start = today.addingTimeInterval(-Double(dayCount - 1) * 86400)
        dateDomain = start...today.addingTimeInterval(86400)

        var accountBuckets: [AccountReference: [String: DailyUsageBucket]] = [:]
        var accountToday: [AccountReference: String] = [:]
        for input in unique.values {
            guard let snapshot = input.snapshot,
                  Self.matches(snapshot.source, platform: input.account.platform),
                  UsageAnalysisMath.validate(snapshot.buckets) else { continue }
            let sourceToday = UsageAnalysisMath.day(now, timezone: snapshot.timezone)
            accountToday[input.account] = sourceToday
            accountBuckets[input.account] = Dictionary(uniqueKeysWithValues: snapshot.buckets.filter {
                $0.day <= sourceToday && $0.date >= start && $0.date <= today
            }.map { ($0.day, $0) })
        }

        var seen = Set<AccountReference>()
        let orderedAccounts = inputs.map(\.account).filter { seen.insert($0).inserted }
        var result: [StackedUsageDay] = []
        for offset in 0..<dayCount {
            let day = UsageAnalysisMath.day(start.addingTimeInterval(Double(offset) * 86400), timezone: "UTC")
            var segments: [StackedUsageSegment] = []
            var lower: Int64 = 0
            var returnedAccounts = 0
            var partial = false
            var cached = false
            var overflow = false
            for account in orderedAccounts {
                guard let bucket = accountBuckets[account]?[day] else { continue }
                returnedAccounts += 1
                let segmentPartial = bucket.isPartial || day >= (accountToday[account] ?? localToday)
                let segmentCached = bucket.isCached == true
                partial = partial || segmentPartial
                cached = cached || segmentCached
                guard let upper = UsageAnalysisMath.sum([lower, bucket.tokens]) else {
                    overflow = true
                    continue
                }
                segments.append(.init(account: account, tokens: bucket.tokens, lower: lower, upper: upper,
                                      isPartial: segmentPartial, isCached: segmentCached,
                                      returnedAccounts: 1, expectedAccounts: 1))
                lower = upper
            }
            let missing = unique.count - returnedAccounts
            result.append(.init(day: day, totalTokens: returnedAccounts == 0 || overflow ? nil : lower,
                                segments: overflow ? [] : segments, missingAccounts: missing,
                                isPartial: partial || missing > 0 || overflow,
                                isCached: cached, hasOverflow: overflow))
        }
        buckets = result
        let returnedTotals = result.compactMap(\.totalTokens)
        let sum = UsageAnalysisMath.sum(returnedTotals)
        hasOverflow = result.contains(where: \.hasOverflow) || (!returnedTotals.isEmpty && sum == nil)
        totalTokens = returnedTotals.isEmpty || hasOverflow ? nil : sum
        completeDays = result.filter { $0.totalTokens != nil && !$0.isPartial }.count
    }

    private static func matches(_ source: UsageAnalysisSource, platform: UsagePlatform) -> Bool {
        switch (source, platform) {
        case (.deepSeek, .deepSeek), (.chatGPT, .chatGPT), (.zhipu, .zhipu): true
        default: false
        }
    }
}
