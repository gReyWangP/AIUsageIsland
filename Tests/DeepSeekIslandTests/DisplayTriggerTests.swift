import XCTest
@testable import DeepSeekIsland

@MainActor
final class DisplayTriggerTests: XCTestCase {
    func testIndependentTriggerChoicesSurviveRestartWithoutChangingStatusPreference() {
        let name = "DisplayTriggerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "showsMenuBarItem")
        let settings = IslandSettings(defaults: defaults)
        XCTAssertTrue(settings.centralHoverEnabled)
        XCTAssertFalse(settings.menuBarHoverEnabled)
        XCTAssertFalse(settings.showsMenuBarItem)
        settings.centralHoverEnabled = false
        settings.menuBarHoverEnabled = true
        settings.showsMenuBarItem = true
        let restored = IslandSettings(defaults: defaults)
        XCTAssertFalse(restored.centralHoverEnabled)
        XCTAssertTrue(restored.menuBarHoverEnabled)
        XCTAssertTrue(restored.showsMenuBarItem)
        restored.showsMenuBarItem = false
        let hidden = IslandSettings(defaults: defaults)
        XCTAssertTrue(hidden.menuBarHoverEnabled, "Hiding status icon must preserve the user's hover choice")
        XCTAssertFalse(hidden.centralHoverEnabled)
    }
}

final class MenuBarHoverStateTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 100)
    func testPassingIconDoesNotOpenAndStayingOpensAfterDelay() {
        var state = MenuBarHoverState()
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start)
        XCTAssertEqual(state.mode, .hidden)
        state.update(iconInside: false, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(0.1))
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(1))
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(1.31))
        XCTAssertEqual(state.mode, .preview)
    }
    func testCrossingGapAndEnteringCardKeepsPreviewThenLeavingCloses() {
        var state = MenuBarHoverState()
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start)
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(0.31))
        state.update(iconInside: false, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(0.4))
        state.update(iconInside: false, cardInside: true, enabled: true, available: true, at: start.addingTimeInterval(0.6))
        XCTAssertEqual(state.mode, .preview)
        state.update(iconInside: false, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(1))
        state.update(iconInside: false, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(1.41))
        XCTAssertEqual(state.mode, .hidden)
    }
    func testClickWorksWithHoverOffAndPinnedCardStaysUntilDismissed() {
        var state = MenuBarHoverState()
        state.togglePinned()
        state.update(iconInside: false, cardInside: false, enabled: false, available: true, at: start)
        XCTAssertEqual(state.mode, .pinned)
        state.dismiss()
        XCTAssertEqual(state.mode, .hidden)
    }
    func testClosingByClickDoesNotImmediatelyReopenUnderStationaryPointer() {
        var state = MenuBarHoverState()
        state.togglePinned()
        state.togglePinned()
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start)
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(2))
        XCTAssertEqual(state.mode, .hidden)
        state.update(iconInside: false, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(3))
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(4))
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(4.31))
        XCTAssertEqual(state.mode, .preview)
    }
    func testMissingIconOrSuspendedApplicationClosesEvenPinnedCard() {
        var state = MenuBarHoverState()
        state.togglePinned()
        state.update(iconInside: true, cardInside: true, enabled: true, available: false, at: start)
        XCTAssertEqual(state.mode, .hidden)
    }
    func testTurningHoverOffClosesOnlyPreviewAndRequiresNewEntry() {
        var state = MenuBarHoverState()
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start)
        state.update(iconInside: true, cardInside: false, enabled: true, available: true, at: start.addingTimeInterval(0.31))
        state.update(iconInside: true, cardInside: false, enabled: false, available: true, at: start.addingTimeInterval(1))
        XCTAssertEqual(state.mode, .hidden)
        state.togglePinned()
        state.update(iconInside: false, cardInside: false, enabled: false, available: true, at: start.addingTimeInterval(2))
        XCTAssertEqual(state.mode, .pinned)
    }
}

final class CentralHoverOptionTests: XCTestCase {
    func testDisabledCentralTriggerCannotShowOrKeepCompactButManualDetailsStillWork() {
        let layout = NotchLayout(frame: NSRect(x: 0, y: 0, width: 1512, height: 982), topLeft: nil, topRight: nil)
        let state = IslandHoverState()
        let pointer = NSPoint(x: 756, y: 981)
        for mode in [IslandPresentation.Mode.hidden, .compact] {
            XCTAssertFalse(state.shouldShow(in: layout, pointer: pointer, mode: mode, pinned: false,
                compactSize: CGSize(width: 565, height: 55), detailSize: CGSize(width: 565, height: 400),
                excluding: nil, enabled: false))
        }
        XCTAssertTrue(state.shouldShow(in: layout, pointer: pointer, mode: .expanded, pinned: false,
            compactSize: CGSize(width: 565, height: 55), detailSize: CGSize(width: 565, height: 400),
            excluding: nil, enabled: false))
    }
}

final class DisplayEntryPolicyTests: XCTestCase {
    func testEmptyAccountSetupUsesSettingsWhenCentralIsDisabled() {
        XCTAssertEqual(DisplayEntryPolicy.startup(guideRequired: false, accountsEmpty: true, centralHoverEnabled: false), .settings)
        XCTAssertEqual(DisplayEntryPolicy.startup(guideRequired: false, accountsEmpty: true, centralHoverEnabled: true), .details)
    }
    func testGuideAndBackgroundStartupKeepExistingBehavior() {
        XCTAssertEqual(DisplayEntryPolicy.startup(guideRequired: true, accountsEmpty: true, centralHoverEnabled: false), .guide)
        XCTAssertEqual(DisplayEntryPolicy.startup(guideRequired: false, accountsEmpty: false, centralHoverEnabled: false), .none)
    }
}
