import Foundation

struct UsageEntry: Codable, Equatable {
    let date: Date
    let amount: Decimal
    let currency: String
}

struct UsageTotals {
    let today: Decimal
    let lastSevenDays: Decimal
    let month: Decimal
}

final class UsageLedger: Codable {
    var firstObserved: Date?
    var lastBalance: Decimal?
    var lastCurrency: String?
    var entries: [UsageEntry] = []

    func resetBaseline() {
        lastBalance = nil
        lastCurrency = nil
    }

    @discardableResult
    func record(balance: Decimal, currency: String, at date: Date) -> UsageEntry? {
        if firstObserved == nil { firstObserved = date }
        defer {
            lastBalance = balance
            lastCurrency = currency
        }
        guard let previous = lastBalance, lastCurrency == currency, previous > balance else { return nil }
        let entry = UsageEntry(date: date, amount: previous - balance, currency: currency)
        entries.append(entry)
        return entry
    }

    func totals(now: Date, calendar: Calendar, currency: String) -> UsageTotals {
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart)!
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        func sum(since start: Date) -> Decimal {
            entries.filter { $0.currency == currency && $0.date >= start && $0.date <= now }
                .reduce(Decimal.zero) { $0 + $1.amount }
        }
        return UsageTotals(today: sum(since: todayStart), lastSevenDays: sum(since: weekStart), month: sum(since: monthStart))
    }
}
