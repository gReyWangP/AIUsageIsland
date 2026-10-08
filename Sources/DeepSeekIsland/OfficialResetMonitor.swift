import Combine
import Foundation

protocol OfficialResetFetching: Sendable {
    func fetch(etag: String?) async throws -> OfficialResetFetchResult
}
enum OfficialResetFetchResult: Sendable {
    case unchanged
    case updated(OfficialResetFeed, etag: String?)
}
struct PublicOfficialResetClient: OfficialResetFetching {
    func fetch(etag: String?) async throws -> OfficialResetFetchResult {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://codex-resets.com/api/v1/status")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ApplicationVersion.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 304 { return .unchanged }
        guard http.statusCode == 200, data.count <= 131_072 else { throw URLError(.badServerResponse) }
        return .updated(try OfficialResetFeed.decode(data), etag: http.value(forHTTPHeaderField: "ETag"))
    }
}

@MainActor
final class OfficialResetMonitor: ObservableObject {
    @Published private(set) var latest: OfficialResetAnnouncement?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var error: String?
    @Published private(set) var checking = false
    var onNotice: ((UsageAlertMessage) async -> Void)?
    private let settings: IslandSettings
    private let model: IslandModel
    private let defaults: UserDefaults
    private let client: any OfficialResetFetching
    private var ledger: OfficialResetLedger
    private var etag: String?
    private var nextCheck = Date.distantPast
    private var lastAttempt: Date?
    private var failures = 0
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var generation = 0
    private var needsBaseline = false
    private let storageKey = "officialResetSeenV1"

    init(settings: IslandSettings, model: IslandModel, defaults: UserDefaults = .standard,
         client: any OfficialResetFetching = PublicOfficialResetClient()) {
        self.settings = settings; self.model = model; self.defaults = defaults; self.client = client
        needsBaseline = defaults.bool(forKey: "officialResetPendingBaselineV1")
        ledger = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(OfficialResetLedger.self, from: $0) } ?? .init()
        $latest.sink { [weak state = model.officialResetCard] in state?.announcement = $0 }.store(in: &subscriptions)
        $lastChecked.sink { [weak state = model.officialResetCard] in state?.lastChecked = $0 }.store(in: &subscriptions)
        $error.sink { [weak state = model.officialResetCard] in state?.error = $0 }.store(in: &subscriptions)
        let changes: [AnyPublisher<Void, Never>] = [

            settings.$alertsScheduleEnabled.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertStartMinute.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertEndMinute.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertsSnoozedUntil.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()]
        Publishers.MergeMany(changes).sink { [weak self] in self?.generation += 1 }.store(in: &subscriptions)
        settings.$officialResetAlertsEnabled.removeDuplicates().dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.generation += 1
            if enabled {
                // 关闭期间没有网络请求；重新开启时先建立当前公告基线，不补发旧消息。
                self.needsBaseline = true; self.defaults.set(true, forKey: "officialResetPendingBaselineV1")
                self.etag = nil; self.nextCheck = .distantPast
            }
        }.store(in: &subscriptions)
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { await check() }
    }
    func check(manual: Bool = false, now: Date = .now) async {
        guard settings.officialResetAlertsEnabled, model.networkAvailable, !model.isSleeping, !checking,
              lastAttempt.map({ now.timeIntervalSince($0) >= 30 }) ?? true,
              manual || now >= nextCheck else { return }
        checking = true; lastAttempt = now
        let version = generation
        defer { checking = false }
        do {
            let result = try await client.fetch(etag: etag)
            guard model.networkAvailable, !model.isSleeping else { return }
            if case .updated(let feed, let tag) = result {
                guard abs(feed.generatedAt.timeIntervalSince(now)) <= 3600 else { throw URLError(.cannotParseResponse) }
                if version == generation { etag = tag }
                latest = feed.events.filter {
                    ($0.phase == .scheduled && $0.latestExpectedAt.map { $0 > now } == true)
                        || now.timeIntervalSince($0.announcedAt) <= 86400
                }
                    .max { $0.announcedAt < $1.announcedAt }
                let notices = ledger.observe(feed.events, now: now, allowed: !needsBaseline && settings.officialResetAlertsEnabled
                    && generation == version && settings.allowsReminder(at: now))
                if version == generation {
                    needsBaseline = false; defaults.set(false, forKey: "officialResetPendingBaselineV1")
                }
                if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: storageKey) }
                for event in notices {
                    guard settings.officialResetAlertsEnabled, version == generation, settings.allowsReminder() else { break }
                    await onNotice?(event.message)
                }
            }
            lastChecked = now; error = nil; failures = 0
            if version == generation { nextCheck = now.addingTimeInterval(900) }
        } catch {
            guard version == generation else { return }
            self.error = "公告暂时无法更新，保留上次结果。"
            failures = min(failures + 1, 2)
            nextCheck = now.addingTimeInterval(900 * pow(2, Double(failures)))
        }
    }
}
