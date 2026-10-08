import Foundation

/// Owns the quota/rotation transaction; the runtime owns account lifetime and published state.
@MainActor
struct ChatGPTUsageAdapter {
    let service: any ChatGPTServing

    func fetch(
        grant: ChatGPTGrant,
        persistRotatedGrant: (ChatGPTGrant) -> Bool,
        isCurrent: () -> Bool
    ) async throws -> ChatGPTQuota {
        func checkCurrent() throws {
            guard isCurrent() else { throw UsageRefreshFailure.cancelled }
            try Task.checkCancellation()
        }
        do {
            try checkCurrent()
            let quota: ChatGPTQuota
            do {
                quota = try await service.fetchQuota(grant: grant)
            } catch {
                guard Self.failure(for: error) == .authorization else { throw error }
                try checkCurrent()
                let rotated = try await service.refresh(grant)
                // Rotation consumes a single-use token. Persist a returned replacement even
                // if this task was cancelled, but never resurrect a removed/replaced account.
                guard isCurrent() else { throw UsageRefreshFailure.cancelled }
                guard persistRotatedGrant(rotated) else { throw UsageRefreshFailure.credentialPersistence }
                try checkCurrent()
                quota = try await service.fetchQuota(grant: rotated)
            }
            try checkCurrent()
            return quota
        } catch {
            let failure = Self.failure(for: error)
            // A service may finish with an error after its task was cancelled.
            // Failed persistence is different: rotation has already changed the credentials
            // and the user must know that the replacement could not be saved.
            if Task.isCancelled, failure != .credentialPersistence {
                throw UsageRefreshFailure.cancelled
            }
            throw failure
        }
    }

    static func failure(for error: Error) -> UsageRefreshFailure {
        if let shared = UsageRefreshFailure.sharedFailure(for: error) { return shared }
        if let error = error as? ChatGPTAccountError {
            switch error {
            case .authorization: return .authorization
            case .server(let status): return .http(status)
            case .invalidResponse: return .invalidResponse
            }
        }
        if let error = error as? ChatGPTQuotaError {
            switch error {
            case .authorization: return .authorization
            case .noQuota: return .noQuota
            case .invalidResponse: return .invalidResponse
            }
        }
        return .unknown
    }
}
