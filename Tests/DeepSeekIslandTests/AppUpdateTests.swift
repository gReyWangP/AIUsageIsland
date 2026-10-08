import AppKit
import SwiftUI
import XCTest
@testable import DeepSeekIsland

@MainActor
final class AppUpdateTests: XCTestCase {
    private final class Backend: AppUpdateBackend {
        let defaults: UserDefaults
        var canCheckForUpdates = true
        var onChange: (() -> Void)?
        var checks = 0
        var writes = 0
        var automaticallyChecksForUpdates: Bool {
            get { defaults.bool(forKey: "SUEnableAutomaticChecks") }
            set { writes += 1; defaults.set(newValue, forKey: "SUEnableAutomaticChecks"); onChange?() }
        }
        init(_ defaults: UserDefaults) { self.defaults = defaults }
        func checkForUpdates() { checks += 1; canCheckForUpdates = false; onChange?() }
        func finish() { canCheckForUpdates = true; onChange?() }
    }
    func testUpdateSettingsFitsViewport() async throws {
        _ = NSApplication.shared
        let name = "AppUpdateRender." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AppUpdateService(backend: Backend(defaults))
        let view = NSHostingView(rootView: AppUpdateSettingsView(service: service).frame(width: 440))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, 440)
        XCTAssertLessThan(view.fittingSize.height, 220)
        XCTAssertFalse(service.automaticallyChecksForUpdates)
    }
    private func withBackend(_ body: (Backend) -> Void) {
        let name = "AppUpdateTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(Backend(defaults))
    }
    func testConstructionPreservesExistingAutomaticPreferenceWithoutWrites() {
        withBackend { backend in
            backend.defaults.set(true, forKey: "SUEnableAutomaticChecks")
            let service = AppUpdateService(backend: backend)
            XCTAssertTrue(service.automaticallyChecksForUpdates)
            XCTAssertEqual(backend.writes, 0)
        }
    }
    func testManualCheckWorksWithAutomaticOffAndRejectsDuplicate() {
        withBackend { backend in
            var presentations = 0
            let service = AppUpdateService(backend: backend, beforePresentation: { presentations += 1 })
            XCTAssertFalse(service.automaticallyChecksForUpdates)
            service.checkForUpdates()
            service.checkForUpdates()
            XCTAssertEqual(backend.checks, 1)
            XCTAssertEqual(presentations, 1)
            XCTAssertFalse(service.canCheckForUpdates)
            backend.finish()
            XCTAssertTrue(service.canCheckForUpdates)
            service.checkForUpdates()
            XCTAssertEqual(backend.checks, 2)
        }
    }
    func testUserChoiceSurvivesReconstructionAndDisablingKeepsManualAvailable() {
        withBackend { backend in
            let service = AppUpdateService(backend: backend)
            service.setAutomaticChecks(true)
            let restored = AppUpdateService(backend: Backend(backend.defaults))
            XCTAssertTrue(restored.automaticallyChecksForUpdates)
            restored.setAutomaticChecks(false)
            XCTAssertFalse(AppUpdateService(backend: Backend(backend.defaults)).automaticallyChecksForUpdates)
            XCTAssertTrue(restored.canCheckForUpdates)
        }
    }
}
