import Carbon
import XCTest
@testable import DeepSeekIsland

@MainActor
final class SystemUtilityTests: XCTestCase {
    final class LoginBackend: LoginLaunchBackend {
        var status: LoginLaunchStatus = .notRegistered
        var fails = false
        func setEnabled(_ enabled: Bool) async throws {
            if fails { throw NSError(domain: "test", code: 1) }
            status = enabled ? .enabled : .notRegistered
        }
    }
    func testLoginFailureDoesNotPretendEnabled() async {
        let backend = LoginBackend()
        let controller = LoginLaunchController(backend: backend)
        backend.fails = true
        await controller.setEnabled(true)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.error)
        backend.fails = false
        await controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        backend.status = .requiresApproval
        controller.refreshStatus()
        XCTAssertTrue(controller.statusText.contains("批准"))
        await controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
    }
    func testShortcutsRequireModifierAndRejectDuplicates() {
        let key = KeyboardShortcut(keyCode: 0, modifiers: 256, keyLabel: "A")
        XCTAssertTrue(key.isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 0, modifiers: 512, keyLabel: "A").isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 999, modifiers: 256, keyLabel: "A").isValid)
        XCTAssertEqual(ShortcutValidation.error(for: key, action: .refresh, bindings: [.toggle: key]), "此快捷键已用于展开／收起详情")
    }
    func testAlertAndShortcutPreferencesPersistWithDefaultsOff() {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        XCTAssertFalse(settings.alertsEnabled)
        XCTAssertTrue(settings.shortcutBindings.isEmpty)
        settings.shortcutBindings[.refresh] = KeyboardShortcut(keyCode: 15, modifiers: 2304, keyLabel: "R")
        settings.alertsEnabled = true
        settings.alertMetrics = [.zhipuWeek]
        let restored = IslandSettings(defaults: store)
        XCTAssertEqual(restored.alertMetrics, [.zhipuWeek])
        XCTAssertEqual(restored.shortcutBindings[.refresh]?.keyLabel, "R")
    }
}

@MainActor
final class HotKeyRegistrationTests: XCTestCase {
    func testOccupiedShortcutIsRejectedAndExistingPreferencePreserved() throws {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: store)
        let controller = GlobalShortcutController(settings: settings, perform: { _ in })
        defer { controller.shutdown() }
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        var claimed: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(kVK_F19), modifiers, EventHotKeyID(signature: 0x54455354, id: 99), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &claimed)
        guard result == noErr, let claimed else { throw XCTSkip("隔离测试组合键已被占用") }
        defer { UnregisterEventHotKey(claimed) }
        let existing = KeyboardShortcut(keyCode: UInt32(kVK_F18), modifiers: modifiers, keyLabel: "F18")
        controller.set(existing, for: .refresh)
        XCTAssertNil(controller.error)
        controller.set(KeyboardShortcut(keyCode: UInt32(kVK_F19), modifiers: modifiers, keyLabel: "F19"), for: .refresh)
        XCTAssertNotNil(controller.error)
        XCTAssertEqual(settings.shortcutBindings[.refresh], existing)
        controller.set(nil, for: .refresh)
        XCTAssertNil(settings.shortcutBindings[.refresh])
        controller.set(existing, for: .refresh)
        controller.shutdown()
        controller.restore()
        var reclaimed: EventHotKeyRef?
        let reclaimResult = RegisterEventHotKey(existing.keyCode, modifiers,
            EventHotKeyID(signature: 0x54455354, id: 100), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reclaimed)
        defer { if let reclaimed { UnregisterEventHotKey(reclaimed) } }
        XCTAssertEqual(reclaimResult, noErr, "关闭监听后，视图销毁不应重新注册快捷键")
    }
}
