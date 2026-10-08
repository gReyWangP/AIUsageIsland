import Foundation

struct ResetQuotaObservation {
    let metric: UsageMetric
    let remaining: Double
    let resetAt: Date
    let fresh: Bool
}

struct ResetRefreshSchedule {
    private struct Entry {
        let resetAt: Date
        let baseline: Double
        var nextAttempt: Date
        var attempts = 0
        var completed = false
    }
    private var entries: [UsageMetric: Entry] = [:]

    mutating func reconcile(_ observations: [ResetQuotaObservation], at now: Date) {
        let active = Set(observations.map(\.metric))
        entries = entries.filter { active.contains($0.key) }
        for observation in observations {
            guard observation.fresh, observation.remaining.isFinite else { continue }
            if var entry = entries[observation.metric] {
                let gain = observation.remaining > entry.baseline + 0.5
                    || (entry.baseline <= 0.001 && observation.remaining > 0.001)
                if observation.remaining >= 20 || (now >= entry.resetAt && gain) { entry.completed = true }
                entries[observation.metric] = entry
                // 到期后继续保留原窗口的有限重试，直到额度真正恢复或次数耗尽。
                if observation.resetAt == entry.resetAt || (!entry.completed && now >= entry.resetAt) { continue }
            }
            guard observation.remaining < 20, observation.resetAt >= now.addingTimeInterval(-300) else { continue }
            entries[observation.metric] = Entry(resetAt: observation.resetAt, baseline: observation.remaining,
                                                nextAttempt: observation.resetAt)
        }
    }

    func duePlatforms(at now: Date) -> [UsagePlatform] {
        let due = Set(entries.filter { !$0.value.completed && $0.value.attempts < 3 && now >= $0.value.nextAttempt }
            .map { $0.key.platform })
        return UsagePlatform.allCases.filter { due.contains($0) }
    }

    mutating func recordAttempt(for platform: UsagePlatform, at now: Date) {
        for metric in Array(entries.keys) where metric.platform == platform {
            guard var entry = entries[metric], !entry.completed, entry.attempts < 3, now >= entry.nextAttempt else { continue }
            entry.attempts += 1
            entry.nextAttempt = now.addingTimeInterval(entry.attempts == 1 ? 60 : 120)
            if entry.attempts == 3 { entry.completed = true }
            entries[metric] = entry
        }
    }
}

extension AccountRuntime {
    func resetQuotaObservations(at now: Date = .now) -> [ResetQuotaObservation] {
        guard platformAccounts.enabled.contains(account.platform),
              hasConnectedAccount(for: account.platform), !zhipuSigningIn, !chatGPTSigningIn else { return [] }
        return UsageMetric.allCases.filter { $0.platform == account.platform }.compactMap { metric in
            guard case .limited(let window) = quotaWindow(for: metric), let resetAt = window.resetAt else { return nil }
            return ResetQuotaObservation(metric: metric, remaining: window.remainingPercent, resetAt: resetAt,
                fresh: freshness(for: account.platform, at: now).allowsAlerts)
        }
    }
}
