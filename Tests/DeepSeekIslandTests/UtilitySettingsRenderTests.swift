import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class UtilitySettingsRenderTests: XCTestCase {
    func testReminderPreferencesRenderInBothThemesWithoutRequestingPermission() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = IslandModel(defaults: defaults, sessionRoot: root)
        model.networkAvailable = false
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: defaults, backend: UsageAlertsControllerTests.Notifications())
        for mode in [AppearanceMode.light, .dark] {
            settings.appearanceMode = mode
            let content = ReminderPreferencesView(model: model, settings: settings, alerts: alerts)
                .padding(18).frame(width: 480, height: 560).background(IslandSettingsBackground(settings: settings))
                .environment(\.colorScheme, mode.colorScheme!)
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = mode.nsAppearance; window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 560)
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/dsi-reminder-preferences-\(mode.rawValue).png"))
            XCTAssertEqual(hosting.bounds.height, 560)
            window.close()
        }
    }
    func testResetAppointmentFitsInBothThemes() async throws {
        _ = NSApplication.shared
        let store = UserDefaults(suiteName: UUID().uuidString)!
        let settings = IslandSettings(defaults: store)
        let controller = ResetReminderController(defaults: store, backend: ResetReminderTests.Backend())
        let event = ResetReminderTests().event(ambiguous: true)
        for mode in [AppearanceMode.light, .dark] {
            settings.appearanceMode = mode
            let hosting = NSHostingView(rootView: ResetReminderView(event: event, settings: settings, controller: controller, onFinish: {}))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 510), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = mode.nsAppearance; window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 450, height: 510)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.fittingSize.width, 450)
            XCTAssertEqual(hosting.fittingSize.height, 510)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/dsi-reset-reminder-\(mode.rawValue).png"))
            window.close()
        }
    }
    func testGeneralSettingsFitsViewportInBothThemes() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        settings.alertsEnabled = true
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = IslandModel(defaults: store, sessionRoot: root)
        model.networkAvailable = false
        model.platformAccounts = PlatformAccounts(enabled: [.chatGPT])
        model.renameAccount(AccountProfileEntry.legacyID, platform: .chatGPT, label: "我的 ChatGPT")
        model.accountProfiles.add(platform: .chatGPT, label: "第二个 ChatGPT")
        settings.migrateAccountReminders(model)
        let backend = UsageAlertsControllerTests.Notifications()
        let alerts = UsageAlertsController(model: model, settings: settings, onOpen: {}, defaults: store, backend: backend)
        await alerts.updatePermission()
        let login = LoginLaunchController(backend: SystemUtilityTests.LoginBackend())
        let shortcuts = GlobalShortcutController(settings: settings, perform: { _ in })
        defer { shortcuts.shutdown() }
        for mode in [AppearanceMode.light, .dark] {
            settings.appearanceMode = mode
            let content = UtilitySettingsView(model: model, settings: settings, login: login, alerts: alerts, shortcuts: shortcuts)
                .padding(18).frame(width: 480, height: 680).background(IslandSettingsBackground(settings: settings))
                .environment(\.colorScheme, mode.colorScheme!)
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = mode.nsAppearance
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 680)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            XCTAssertEqual(hosting.bounds.width, 480)
            XCTAssertEqual(hosting.bounds.height, 680)
            var contrasted = 0
            for y in stride(from: 10, to: bitmap.pixelsHigh - 10, by: 4) {
                for x in stride(from: 10, to: bitmap.pixelsWide - 10, by: 4) {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if mode == .dark ? color.redComponent > 0.4 : color.redComponent < 0.6 { contrasted += 1 }
                }
            }
            XCTAssertGreaterThan(contrasted, 100, "原生通用设置不能渲染为空白")
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/dsi-utility-settings-\(mode.rawValue).png"))
            if let path = ProcessInfo.processInfo.environment["AI_USAGE_PREVIEW_DIR"] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("settings-reminders-\(mode.rawValue).png"))
            }
            window.close()
        }
    }
    func testPersonalAppointmentKeepsFooterVisibleWithExistingReservation() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        let controller = QuotaReminderController(defaults: defaults, backend: PersonalQuotaReminderTests.Backend())
        let plan = try QuotaReminderPlan.make(metric: .zhipuWeek, resetAt: .now.addingTimeInterval(7200), lead: .atTime, accountLabel: "工作账号")
        await controller.save(plan)
        for mode in [AppearanceMode.light, .dark] {
            settings.appearanceMode = mode
            let view = QuotaReminderView(proposal: plan, controller: controller, settings: settings, onFinish: {})
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = mode.nsAppearance; window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 450, height: 440); hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.fittingSize.width, 450); XCTAssertEqual(hosting.fittingSize.height, 440)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/dsi-personal-appointment-\(mode.rawValue).png"))
            window.close()
        }
    }

    func testExpandedAccountAndThresholdSettingsRenderInBothThemes() async throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        let root = SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root.directory) }
        let settings = IslandSettings(defaults: defaults), model = IslandModel(defaults: defaults, sessionRoot: root)
        model.platformAccounts = PlatformAccounts(enabled: Set(UsagePlatform.allCases))
        for platform in UsagePlatform.allCases { model.accountProfiles.add(platform: platform, label: "工作账号") }
        for mode in [AppearanceMode.light, .dark] {
            settings.appearanceMode = mode
            let view = ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AccountSettingsView(model: model, settings: settings, initiallyExpanded: true)
                    Divider()
                    AlertThresholdSettingsView(settings: settings, initiallyExpanded: true)
                }.padding(20)
            }.font(.system(size: 11)).frame(width: 420, height: 550)
                .background(IslandSettingsBackground(settings: settings)).environment(\.colorScheme, mode.colorScheme!)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = mode.nsAppearance; window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 550); hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/dsi-expanded-account-settings-\(mode.rawValue).png"))
            window.close()
        }
    }

}
