import AppKit
import SwiftUI
import XCTest
import UserNotifications
@testable import DeepSeekIsland

@MainActor
final class OfficialResetTests: XCTestCase {
    private let announced = ISO8601DateFormatter().date(from: "2026-10-02T02:14:51Z")!
    private func store() -> UserDefaults {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        // Feed tests exercise an explicitly subscribed user, independent of installation defaults.
        defaults.set(true, forKey: "officialResetAlertsEnabled")
        return defaults
    }
    private func payload(source: String = "x_post", date: String = "2026-10-02T04:00:00Z", scheduled: Bool = true) -> Data {
        Data("""
        {"data":{"latest_reset":null,"scheduled_reset":\(scheduled ? """
        {"id":"2105843926221660585","status":"scheduled","reset_type":"regular","announced_at":"2026-10-02T02:14:51Z","scheduled_for":"2026-10-02T17:00:00Z","text":"Global reset landing tomorrow 10am PST for all paid ChatGPT accounts.","source":{"type":"\(source)","author":"thsottiaux","url":"https://x.com/thsottiaux/status/2105843926221660585"}}
        """ : "null"),"active_watch":null},"meta":{"generated_at":"\(date)"}}
        """.utf8)
    }
    func testDetailCardSharesMonitorResultAndFreshnessWithoutOwnFetch() async throws {
        let model = IslandModel(), client = FakeFeed(try OfficialResetFeed.decode(payload()))
        let monitor = OfficialResetMonitor(settings: IslandSettings(defaults: store()), model: model,
            defaults: store(), client: client)
        let now = announced.addingTimeInterval(3600)
        await monitor.check(now: now)
        XCTAssertEqual(model.officialResetCard.announcement, monitor.latest)
        XCTAssertNotNil(model.officialResetCard.announcement)
        XCTAssertEqual(model.officialResetCard.lastChecked, now)
        XCTAssertNil(model.officialResetCard.error)
        await monitor.check(manual: true, now: now.addingTimeInterval(1))
        XCTAssertEqual(model.officialResetCard.lastChecked, now)
    }
    func testNewSubscriptionDefaultsOnAndOptOutPersistsIndependentlyOfQuotaAlerts() {
        let name = UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let s = IslandSettings(defaults: d)
        XCTAssertTrue(s.officialResetAlertsEnabled)
        XCTAssertFalse(s.alertsEnabled)
        s.officialResetAlertsEnabled = false
        XCTAssertFalse(IslandSettings(defaults: d).officialResetAlertsEnabled)
    }
    func testExplicitOptOutDoesNotFetchAnnouncementsEvenOnManualCheck() async throws {
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        settings.officialResetAlertsEnabled = false
        let client = FakeFeed(try OfficialResetFeed.decode(payload()))
        let monitor = OfficialResetMonitor(settings: settings, model: IslandModel(), defaults: defaults, client: client)
        await monitor.check(manual: true, now: announced.addingTimeInterval(3600))
        let calls = await client.count()
        XCTAssertEqual(calls, 0)
    }
    func testPacificTomorrowUsesAuthorsDateAndShowsBeijingDSTAmbiguity() throws {
        let feed = try OfficialResetFeed.decode(payload())
        let event = try XCTUnwrap(feed.events.first)
        XCTAssertEqual(event.expectedAt, ISO8601DateFormatter().date(from: "2026-10-02T17:00:00Z"))
        XCTAssertEqual(event.latestExpectedAt, ISO8601DateFormatter().date(from: "2026-10-02T18:00:00Z"))
        XCTAssertTrue(event.timeDescription.contains("10月3日"))
        XCTAssertTrue(event.timeDescription.contains("01:00"))
        XCTAssertTrue(event.timeDescription.contains("02:00"))
        XCTAssertTrue(event.timeDescription.contains("北京时间"))
        XCTAssertFalse(event.message.title.contains("额度已恢复"))
        XCTAssertTrue(event.message.body.contains("不代表"))
        XCTAssertFalse(event.message.recovered)
    }
    func testObservedEventsAreNotOfficialAnnouncementsAndUnsafeSourceRejected() throws {
        XCTAssertTrue(try OfficialResetFeed.decode(payload(source: "observed")).events.isEmpty)
        let bad = String(decoding: payload(), as: UTF8.self).replacingOccurrences(of: "https://x.com/", with: "https://evil.example/")
        XCTAssertTrue(try OfficialResetFeed.decode(Data(bad.utf8)).events.isEmpty)
    }
    func testForecastLinkedToTiboIsStillNotAnExplicitAnnouncement() throws {
        let value = String(decoding: payload(), as: UTF8.self).replacingOccurrences(of: "\"status\":\"scheduled\"", with: "\"status\":\"forecast\"")
        XCTAssertTrue(try OfficialResetFeed.decode(Data(value.utf8)).events.isEmpty)
    }
    func testLedgerNotifiesUpcomingOnFirstRunButDoesNotReplayOnRestartOrEnable() throws {
        let event = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        let now = announced.addingTimeInterval(3600)
        var ledger = OfficialResetLedger()
        XCTAssertEqual(ledger.observe([event], now: now, allowed: true).count, 1)
        let restored = try JSONDecoder().decode(OfficialResetLedger.self, from: JSONEncoder().encode(ledger))
        ledger = restored
        XCTAssertTrue(ledger.observe([event], now: now, allowed: true).isEmpty)
        var muted = OfficialResetLedger()
        XCTAssertTrue(muted.observe([event], now: now, allowed: false).isEmpty)
        XCTAssertTrue(muted.observe([event], now: now, allowed: true).isEmpty)
    }
    func testPassedScheduleAndHistoricalReportsDoNotNotifyOnFirstRun() throws {
        var ledger = OfficialResetLedger()
        let event = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        XCTAssertTrue(ledger.observe([event], now: announced.addingTimeInterval(86400), allowed: true).isEmpty)
        var reported = event; reported.phase = .reported; reported.scheduledFor = nil
        ledger = OfficialResetLedger()
        XCTAssertTrue(ledger.observe([reported], now: announced.addingTimeInterval(3600), allowed: true).isEmpty)
    }
    actor FakeFeed: OfficialResetFetching {
        var calls = 0
        var etags: [String?] = []
        var feed: OfficialResetFeed
        func replace(_ value: OfficialResetFeed) { feed = value }
        init(_ feed: OfficialResetFeed) { self.feed = feed }
        func fetch(etag: String?) async throws -> OfficialResetFetchResult {
            calls += 1; etags.append(etag)
            return etag == nil ? .updated(feed, etag: "sample-tag") : .unchanged
        }
        func count() -> Int { calls }
    }
    func testMonitorFiltersDayOldReportsButKeepsFuturePreannouncements() async throws {
        let now = announced.addingTimeInterval(25 * 3600)
        var reported = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        reported.phase = .reported
        let future = OfficialResetAnnouncement(id: "future", resetType: "regular", phase: .scheduled,
            announcedAt: announced, scheduledFor: now.addingTimeInterval(3600),
            text: "A global reset is scheduled.", sourceURL: reported.sourceURL)
        for (event, expected) in [(reported, Optional<OfficialResetAnnouncement>.none), (future, Optional(future))] {
            let monitor = OfficialResetMonitor(settings: IslandSettings(defaults: store()), model: IslandModel(),
                defaults: store(), client: FakeFeed(.init(events: [event], generatedAt: now)))
            await monitor.check(now: now)
            XCTAssertEqual(monitor.latest, expected)
        }
    }
    func testMonitorStopsWhenOffOfflineOrSleepingAndHonorsIntervalAndETag() async throws {
        let now = announced.addingTimeInterval(3600)
        let data = payload(date: "2026-10-02T03:14:51Z")
        let client = FakeFeed(try OfficialResetFeed.decode(data))
        let d = store(), s = IslandSettings(defaults: store()), model = IslandModel()
        let monitor = OfficialResetMonitor(settings: s, model: model, defaults: d, client: client)
        var notices: [UsageAlertMessage] = []
        monitor.onNotice = { notices.append($0) }
        s.officialResetAlertsEnabled = false; await monitor.check(now: now)
        s.officialResetAlertsEnabled = true; model.networkAvailable = false; await monitor.check(now: now)
        model.networkAvailable = true; model.isSleeping = true; await monitor.check(now: now)
        var count = await client.count(); XCTAssertEqual(count, 0)
        model.isSleeping = false; await monitor.check(now: now)
        count = await client.count(); XCTAssertEqual(count, 1)
        XCTAssertEqual(notices.count, 0)
        await monitor.check(now: now.addingTimeInterval(60))
        count = await client.count(); XCTAssertEqual(count, 1)
        await monitor.check(now: now.addingTimeInterval(901))
        count = await client.count(); XCTAssertEqual(count, 2)
        let tags = await client.etags
        XCTAssertEqual(tags.compactMap { $0 }, ["sample-tag"])
        XCTAssertEqual(notices.count, 0)
    }
    func testReenableSeedsAnnouncementsMissedWhileOffInsteadOfReplaying() async throws {
        let now = announced.addingTimeInterval(3600)
        let empty = OfficialResetFeed(events: [], generatedAt: now)
        let client = FakeFeed(empty), settings = IslandSettings(defaults: store())
        let monitor = OfficialResetMonitor(settings: settings, model: IslandModel(), defaults: store(), client: client)
        var notices = 0; monitor.onNotice = { _ in notices += 1 }
        await monitor.check(now: now)
        settings.officialResetAlertsEnabled = false
        var reported = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        reported.phase = .reported; reported.scheduledFor = nil
        await client.replace(.init(events: [reported], generatedAt: now))
        settings.officialResetAlertsEnabled = true
        await monitor.check(manual: true, now: now.addingTimeInterval(31))
        XCTAssertEqual(notices, 0)
        XCTAssertNotNil(monitor.latest)
    }
    func testInitialDefaultOnUpcomingAnnouncementAndNativeSettingsRendering() async throws {
        _ = NSApplication.shared
        let now = announced.addingTimeInterval(3600)
        let settings = IslandSettings(defaults: store()), model = IslandModel()
        let monitor = OfficialResetMonitor(settings: settings, model: model, defaults: store(),
            client: FakeFeed(try OfficialResetFeed.decode(payload(date: "2026-10-02T03:14:51Z"))))
        var notices = 0; monitor.onNotice = { _ in notices += 1 }
        await monitor.check(now: now)
        XCTAssertEqual(notices, 1, "默认开启时仍需通知当前尚未发生的预告")
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: store(), backend: UsageAlertsControllerTests.Notifications())
        for mode in [AppearanceMode.light, .dark] {
            let view = OfficialResetSettingsView(settings: settings, alerts: alerts, monitor: monitor)
                .toggleStyle(.checkbox).padding(18).frame(width: 420, height: 360, alignment: .topLeading)
                .background(mode == .light ? Color.white : Color.black).environment(\.colorScheme, mode.colorScheme!)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = mode.nsAppearance
            window.contentView = hosting; hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
            try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/dsi-official-reset-\(mode.rawValue).png"))
            window.close()
        }
    }
    actor DelayedFeed: OfficialResetFetching {
        var feed: OfficialResetFeed
        var waiting: CheckedContinuation<Void, Never>?
        var started = false
        var delay = true
        init(_ feed: OfficialResetFeed) { self.feed = feed }
        func replace(_ value: OfficialResetFeed) { feed = value }
        func resume() { waiting?.resume(); waiting = nil }
        func hasStarted() -> Bool { started }
        func fetch(etag: String?) async throws -> OfficialResetFetchResult {
            let snapshot = feed
            started = true
            if delay { delay = false; await withCheckedContinuation { waiting = $0 } }
            return .updated(snapshot, etag: "tag")
        }
    }
    func testOldInFlightResponseCannotConsumeNewEnableBaseline() async throws {
        let now = announced.addingTimeInterval(3600)
        let client = DelayedFeed(.init(events: [], generatedAt: now)), settings = IslandSettings(defaults: store())
        let monitor = OfficialResetMonitor(settings: settings, model: IslandModel(), defaults: store(), client: client)
        var notices = 0; monitor.onNotice = { _ in notices += 1 }
        let first = Task { await monitor.check(now: now) }
        for _ in 0..<100 { if await client.hasStarted() { break }; await Task.yield() }
        settings.officialResetAlertsEnabled = false
        var event = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        event.phase = .reported; event.scheduledFor = nil
        await client.replace(.init(events: [event], generatedAt: now))
        settings.officialResetAlertsEnabled = true
        await client.resume(); await first.value
        await monitor.check(manual: true, now: now.addingTimeInterval(31))
        XCTAssertEqual(notices, 0, "旧请求不能消耗重新开启的公告基线")
        XCTAssertNotNil(monitor.latest)
    }
    func testSnoozeDuringFetchSeedsResponseWithoutLaterReplay() async throws {
        let now = announced.addingTimeInterval(3600)
        let client = DelayedFeed(try OfficialResetFeed.decode(payload(date: "2026-10-02T03:14:51Z")))
        let settings = IslandSettings(defaults: store())
        let monitor = OfficialResetMonitor(settings: settings, model: IslandModel(), defaults: store(), client: client)
        var notices = 0; monitor.onNotice = { _ in notices += 1 }
        let first = Task { await monitor.check(now: now) }
        for _ in 0..<100 { if await client.hasStarted() { break }; await Task.yield() }
        settings.snoozeRemindersToday(); settings.alertsSnoozedUntil = nil
        await client.resume(); await first.value
        await monitor.check(manual: true, now: now.addingTimeInterval(31))
        XCTAssertEqual(notices, 0)
    }
    func testReenableBaselineSurvivesRestartBeforeSuccessfulCheck() async throws {
        let now = announced.addingTimeInterval(3600), defaults = store()
        let settings = IslandSettings(defaults: defaults), model = IslandModel()
        let client = FakeFeed(.init(events: [], generatedAt: now))
        let original = OfficialResetMonitor(settings: settings, model: model, defaults: defaults, client: client)
        await original.check(now: now)
        settings.officialResetAlertsEnabled = false
        var event = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        event.phase = .reported; event.scheduledFor = nil
        await client.replace(.init(events: [event], generatedAt: now))
        model.networkAvailable = false; settings.officialResetAlertsEnabled = true
        await original.check(now: now.addingTimeInterval(31))
        let restoredModel = IslandModel()
        let restored = OfficialResetMonitor(settings: IslandSettings(defaults: defaults), model: restoredModel,
            defaults: defaults, client: client)
        var notices = 0; restored.onNotice = { _ in notices += 1 }
        await restored.check(now: now.addingTimeInterval(32))
        XCTAssertEqual(notices, 0, "重新开启后尚未联网，重启也不能补发旧公告")
        XCTAssertNotNil(restored.latest)
    }
    func testStaleFeedDoesNotAnnounceOrAdvanceLastChecked() async throws {
        let client = FakeFeed(try OfficialResetFeed.decode(payload(date: "2026-09-30T03:14:51Z")))
        let monitor = OfficialResetMonitor(settings: IslandSettings(defaults: store()), model: IslandModel(), defaults: store(), client: client)
        var notices = 0; monitor.onNotice = { _ in notices += 1 }
        await monitor.check(now: announced.addingTimeInterval(3600))
        XCTAssertEqual(notices, 0); XCTAssertNil(monitor.lastChecked); XCTAssertNotNil(monitor.error)
    }
    func testIndependentNoticeDoesNotRequireChatGPTAccountOrQuotaMaster() async throws {
        let s = IslandSettings(defaults: store()), model = IslandModel(), backend = UsageAlertsControllerTests.Notifications()
        model.platformAccounts = PlatformAccounts(enabled: [.deepSeek]); model.chatGPTConnected = false
        let alerts = UsageAlertsController(model: model, settings: s, onOpen: {}, defaults: store(), backend: backend)
        let event = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        await alerts.deliverOfficialAnnouncement(event.message)
        XCTAssertEqual(backend.messages.count, 1)
        XCTAssertFalse(s.alertsEnabled)
        s.officialResetAlertsEnabled = false
        await alerts.deliverOfficialAnnouncement(event.message)
        XCTAssertEqual(backend.messages.count, 1)
    }
    func testOfficialNotificationDisabledDuringSendIsDiscardedEvenIfReenabled() async throws {
        let s = IslandSettings(defaults: store()), backend = ReminderPolicyTests.DelayedNotifications()
        let alerts = UsageAlertsController(model: IslandModel(), settings: s, onOpen: {}, defaults: store(), backend: backend)
        let event = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        let send = Task { await alerts.deliverOfficialAnnouncement(event.message) }
        for _ in 0..<100 where !backend.started { await Task.yield() }
        XCTAssertTrue(backend.started)
        s.officialResetAlertsEnabled = false; s.officialResetAlertsEnabled = true
        backend.release?.resume(); backend.release = nil
        await send.value
        XCTAssertTrue(backend.delivered.isEmpty)
    }
    func testSourceActionOpensOriginalAndSnoozeDoesNotOpenIt() throws {
        let s = IslandSettings(defaults: store())
        let alerts = UsageAlertsController(model: IslandModel(), settings: s, onOpen: {}, defaults: store(), backend: UsageAlertsControllerTests.Notifications())
        let event = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        var opened: [URL] = []; alerts.onOpenAnnouncement = { opened.append($0) }
        alerts.handleOfficialAction(OfficialResetAction.view, sourceURL: URL(string: "https://evil.example"))
        XCTAssertTrue(opened.isEmpty)
        alerts.handleOfficialAction(OfficialResetAction.view, sourceURL: event.sourceURL)
        XCTAssertEqual(opened, [event.sourceURL])
        alerts.handleOfficialAction(UsageNotificationAction.snoozeToday, sourceURL: event.sourceURL)
        XCTAssertEqual(opened.count, 1); XCTAssertFalse(s.allowsReminder())
    }
    func testLivePublicFeedWithoutCookiesOrCredentials() async throws {
        guard ProcessInfo.processInfo.environment["DSI_LIVE_PUBLIC_FEED"] == "1" else { throw XCTSkip("Explicit network probe only") }
        if case .updated(let feed, _) = try await PublicOfficialResetClient().fetch(etag: nil) {
            XCTAssertLessThan(abs(feed.generatedAt.timeIntervalSinceNow), 3600)
            print("PUBLIC_FEED_OK events=\(feed.events.count)")
        } else { XCTFail("Initial public request should return data") }
    }
    func testAnnouncementNotificationUsesOwnCategoryAndValidatedOriginalLink() throws {
        let event = try XCTUnwrap(OfficialResetFeed.decode(payload()).events.first)
        let content = SystemUsageNotifications.content(event.message)
        XCTAssertEqual(content.categoryIdentifier, OfficialResetAction.scheduledCategory)
        XCTAssertEqual(content.userInfo["sourceURL"] as? String, event.sourceURL.absoluteString)
        XCTAssertEqual(SystemUsageNotifications.officialCategory().actions.first?.identifier, OfficialResetAction.view)
    }
}
