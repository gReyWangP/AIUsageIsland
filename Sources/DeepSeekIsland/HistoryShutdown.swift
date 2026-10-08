import Foundation

@MainActor
final class HistoryShutdown {
    private var started = false
    private var finished = false
    func begin(timeout: TimeInterval = 3, flush: @escaping @MainActor @Sendable () async -> Void,
               completion: @escaping @MainActor @Sendable () -> Void) {
        guard !started else { return }; started = true
        Task { [self] in await flush(); finish(completion) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in finish(completion) }
    }
    private func finish(_ completion: @MainActor () -> Void) {
        guard !finished else { return }; finished = true; completion()
    }
}
