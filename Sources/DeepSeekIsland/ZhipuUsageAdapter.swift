import Foundation

/// Bridges the browser's callback lifecycle to account-owned usage updates.
/// Identity verification remains in AccountRuntime, which decides whether login can finish.
@MainActor
final class ZhipuUsageAdapter {
    var onQuota: ((Result<ZhipuQuota, UsageRefreshFailure>) -> Bool)?
    var onAnalysis: ((String, Result<UsageAnalysisSnapshot, Error>) -> Void)?
    var onWindowClosed: (() -> Void)?
    private let session: ZhipuWebSession
    private var timeoutTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var isSuspended = false

    init(profileID: UUID) {
        session = ZhipuWebSession(profileID: profileID)
        session.onQuota = { [weak self] result in
            guard let self, !self.isSuspended else { return false }
            switch result {
            case .success(let quota):
                self.cancelTimeout()
                return self.onQuota?(.success(quota)) ?? false
            case .failure(let error):
                let failure = Self.failure(for: error)
                // Loading a new page cancels the previous navigation; that isn't a usage failure.
                guard failure != .cancelled else { return false }
                self.cancelTimeout()
                return self.onQuota?(.failure(failure)) ?? false
            }
        }
        session.onAnalysis = { [weak self] identity, result in
            guard let self, !self.isSuspended else { return }; self.onAnalysis?(identity,result)
        }
        session.onWindowClosed = { [weak self] in
            guard let self, !self.isSuspended else { return }
            self.onWindowClosed?()
        }
    }

    func showLogin() {
        guard !isSuspended else { return }
        cancelTimeout()
        session.showLogin()
    }

    @discardableResult func refresh() -> Bool {
        guard !isSuspended, session.refresh() else { return false }
        cancelTimeout()
        let generation = refreshGeneration
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) }
            catch { return }
            guard let self, !self.isSuspended, self.refreshGeneration == generation else { return }
            self.timeoutTask = nil
            _ = self.onQuota?(.failure(.transport(URLError.timedOut.rawValue)))
        }
        return true
    }

    func suspend() {
        isSuspended = true
        cancelTimeout()
        onQuota = nil; onAnalysis = nil; onWindowClosed = nil
        session.suspend()
    }

    private func cancelTimeout() {
        refreshGeneration += 1
        timeoutTask?.cancel(); timeoutTask = nil
    }

    static func failure(for error: Error) -> UsageRefreshFailure {
        if let shared = UsageRefreshFailure.sharedFailure(for: error) { return shared }
        if let error = error as? ZhipuQuotaError {
            switch error {
            case .authorization: return .authorization
            case .invalidResponse: return .invalidResponse
            }
        }
        return .unknown
    }
}
