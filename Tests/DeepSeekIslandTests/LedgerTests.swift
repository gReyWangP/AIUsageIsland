import XCTest
@testable import DeepSeekIsland

final class LedgerTests: XCTestCase {
    func testFirstSnapshotDoesNotCreateSpend() {
        let ledger = UsageLedger()
        let sample = ledger.record(balance: 100, currency: "CNY", at: .init(timeIntervalSince1970: 100))
        XCTAssertNil(sample)
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func testDecreaseRecordsSpend() {
        let ledger = UsageLedger()
        _ = ledger.record(balance: 100, currency: "CNY", at: .init(timeIntervalSince1970: 100))
        let sample = ledger.record(balance: 98.25, currency: "CNY", at: .init(timeIntervalSince1970: 200))
        XCTAssertEqual(sample?.amount, 1.75)
        XCTAssertEqual(ledger.entries.count, 1)
    }

    func testTopUpDoesNotCountAsNegativeSpend() {
        let ledger = UsageLedger()
        _ = ledger.record(balance: 100, currency: "CNY", at: .init(timeIntervalSince1970: 100))
        XCTAssertNil(ledger.record(balance: 120, currency: "CNY", at: .init(timeIntervalSince1970: 200)))
        let sample = ledger.record(balance: 119, currency: "CNY", at: .init(timeIntervalSince1970: 300))
        XCTAssertEqual(sample?.amount, 1)
    }

    func testResetBaselinePreventsChargingAccountSwitch() {
        let ledger = UsageLedger()
        _ = ledger.record(balance: 100, currency: "CNY", at: .init(timeIntervalSince1970: 100))
        ledger.resetBaseline()
        XCTAssertNil(ledger.record(balance: 20, currency: "CNY", at: .init(timeIntervalSince1970: 200)))
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func testTotalsUseCalendarDayWeekAndMonth() {
        let ledger = UsageLedger()
        let tz = TimeZone(secondsFromGMT: 8)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        func day(_ value: String) -> Date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)!
        }
        ledger.entries = [
            .init(date: day("2026-09-29T02:00:00Z"), amount: 2, currency: "CNY"),
            .init(date: day("2026-09-23T02:00:00Z"), amount: 3, currency: "CNY"),
            .init(date: day("2026-09-20T02:00:00Z"), amount: 5, currency: "CNY"),
            .init(date: day("2026-08-29T02:00:00Z"), amount: 7, currency: "CNY")
        ]
        let totals = ledger.totals(now: day("2026-09-29T04:00:00Z"), calendar: calendar, currency: "CNY")
        XCTAssertEqual(totals.today, 2)
        XCTAssertEqual(totals.lastSevenDays, 5)
        XCTAssertEqual(totals.month, 10)
    }

    func testOldEntriesWithToolLabelsStillDecode() throws {
        let oldData = Data("""
            {"entries":[{"date":100,"amount":1.75,"currency":"CNY","tool":"Codex"}],
             "firstObserved":100,"lastBalance":98.25,"lastCurrency":"CNY"}
            """.utf8)
        let ledger = try JSONDecoder().decode(UsageLedger.self, from: oldData)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries.first?.amount, 1.75)
        XCTAssertEqual(ledger.lastBalance, 98.25)
    }
}
