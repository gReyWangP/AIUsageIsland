import Foundation

protocol DeepSeekServing: Sendable {
    func fetchSummary(token: String) async throws -> AccountSummary
    func fetchProfile(token: String) async throws -> AccountProfile
    func fetchUsage(token: String, currency: String, ranges: UsageRanges) async throws -> OfficialUsageSummary
}

struct DeepSeekBalanceReading {
    let amount: Decimal
    let currency: String
}

enum DeepSeekUsageResult {
    case updated(OfficialUsageSummary)
    case unavailable(UsageRefreshFailure)
}

/// Balance is authoritative for account availability. Auxiliary usage failure must not
/// discard a successful balance or revoke authorization that the balance endpoint accepted.
@MainActor
struct DeepSeekUsageAdapter {
    let service: any DeepSeekServing

    func fetch(token: String,
               isCurrent: () -> Bool,
               onBalance: (DeepSeekBalanceReading) -> Void) async throws -> DeepSeekUsageResult {
        func checkCurrent() throws {
            guard isCurrent() else { throw UsageRefreshFailure.cancelled }
            try Task.checkCancellation()
        }
        do {
            try checkCurrent()
            let summary = try await service.fetchSummary(token: token)
            try checkCurrent()
            guard let selected = summary.balances["CNY"].map({ ("CNY", $0) })
                    ?? summary.balances.first.map({ ($0.key, $0.value) }),
                  !selected.1.isNaN else { throw UsageRefreshFailure.invalidResponse }
            onBalance(.init(amount: selected.1, currency: selected.0))
            try checkCurrent()
            do {
                let usage = try await service.fetchUsage(token: token, currency: selected.0,
                    ranges: UsageRanges(now: .now, calendar: .current))
                try checkCurrent()
                return .updated(usage)
            } catch {
                try checkCurrent()
                let failure = Self.failure(for: error)
                if failure == .cancelled { throw failure }
                return .unavailable(failure)
            }
        } catch {
            if Task.isCancelled { throw UsageRefreshFailure.cancelled }
            throw Self.failure(for: error)
        }
    }

    static func failure(for error: Error) -> UsageRefreshFailure {
        if let shared = UsageRefreshFailure.sharedFailure(for: error) { return shared }
        if let error = error as? PlatformError {
            switch error {
            case .expired: return .authorization
            case .server(let status): return .http(status)
            case .invalidResponse, .invalidAuthorizationURL: return .invalidResponse
            case .cancelled: return .cancelled
            }
        }
        return .unknown
    }
}
