import Combine
import Foundation

struct UsageTrendPoint: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let metric: UsageMetric
    let value: Double
    let unit: String
    let resetAt: Date?
    let segment: Int
}

@MainActor
final class UsageTrendStore: ObservableObject {
    @Published private(set) var points: [UsageTrendPoint] = []
    @Published private(set) var persistenceError: String?
    private let storage: HistoryPersistence
    private var loadTask: Task<Void, Never>?
    private var revision = 0
    private var valid = true
    private var sealed = false
    init(directory: URL, at now: Date = .now, storage: HistoryPersistence? = nil) {
        self.storage = storage ?? HistoryPersistence(directory: directory)
        let read = self.storage.beginLoad([UsageTrendPoint].self, file: "usage-trend.json")
        loadTask = Task { [weak self] in
            let loaded = await read.value
            guard let self, self.valid else { return }
            if let loaded {
                let retained = loaded.filter { $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= 7 * 86400 && $0.value.isFinite && $0.value >= 0 && $0.timestamp.timeIntervalSince1970.isFinite && ($0.resetAt?.timeIntervalSince1970.isFinite ?? true) }
                    .sorted { $0.timestamp < $1.timestamp }
                if self.revision == 0 { self.points = Array(retained.suffix(4000)) }
                else {
                    let fresh = self.points
                    self.points = Array(retained.filter { old in !fresh.contains { $0.metric == old.metric && $0.timestamp <= old.timestamp } })
                    let wasSealed = self.sealed
                    self.sealed = false
                    for point in fresh {
                        self.record(metric: point.metric, value: point.value, unit: point.unit, resetAt: point.resetAt, at: point.timestamp, persist: false)
                    }
                    self.sealed = wasSealed
                    self.persistPoints()
                }
            }
        }
    }
    func stopAcceptingUpdates() { sealed = true }
    func waitUntilLoaded() async { await loadTask?.value }
    func invalidate() { valid = false; loadTask?.cancel(); storage.invalidate() }
    @discardableResult
    func record(metric: UsageMetric, value: Double, unit: String, resetAt: Date?, at now: Date = .now, persist: Bool = true) -> Bool {
        guard valid, !sealed, value.isFinite, value >= 0, now.timeIntervalSince1970.isFinite,
              resetAt?.timeIntervalSince1970.isFinite ?? true else { return false }
        let previous = points.last { $0.metric == metric }
        guard previous.map({ now > $0.timestamp }) ?? true else { return false }
        let breakLine = previous.map { $0.unit != unit || $0.resetAt != resetAt || now.timeIntervalSince($0.timestamp) > 900 || (metric == .deepSeekBalance ? value > $0.value : value < $0.value) } ?? false
        let segment = (previous?.segment ?? 0) + (breakLine ? 1 : 0)
        points.append(.init(id: UUID(), timestamp: now, metric: metric, value: value, unit: unit, resetAt: resetAt, segment: segment))
        points = Array(points.filter { now.timeIntervalSince($0.timestamp) <= 7 * 86400 }.suffix(4000))
        revision += 1
        if persist { persistPoints() }
        return true
    }
    func persistPoints() {
        let savedRevision = revision
        storage.save(points, file: "usage-trend.json") { [weak self] success in
            guard let self, self.valid, self.revision == savedRevision else { return }
            self.persistenceError = success ? nil : "趋势暂时只保存在内存，无法写入本机历史文件。"
        }
    }
    func recent(metric: UsageMetric, days: Int, at now: Date = .now) -> [UsageTrendPoint] {
        points.filter { $0.metric == metric && $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= Double(days) * 86400 }
    }
}

extension AccountRuntime {
    func recordQuotaTrend(at now: Date = .now) {
        var changed = false
        for metric in capabilities.availableMetrics where metric != .deepSeekBalance {
            if case .limited(let window) = quotaWindow(for: metric) {
                let recorded = trend.record(metric: metric, value: min(100, window.usedPercent), unit: "%", resetAt: window.resetAt, at: now, persist: false)
                changed = changed || recorded
            }
        }
        if changed { trend.persistPoints() }
    }
}
