import XCTest
@testable import DeepSeekIsland

final class ScreenTargetTests: XCTestCase {
    @MainActor
    func testScreenChangesUseNewSelectionRatherThanPreviousDisplay() {
        let domain = UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = IslandSettings(defaults: defaults)
        var targets: [ScreenSelection] = []
        let observation = ScreenTarget.observeSelection(of: settings) { targets.append($0) }
        let builtIn = ScreenSelection.display(id: 1, name: "内建")
        let external = ScreenSelection.display(id: 4, name: "外接")
        settings.screenSelection = builtIn
        settings.screenSelection = external
        settings.screenSelection = builtIn
        settings.screenSelection = .automatic
        XCTAssertEqual(targets, [.automatic, builtIn, external, builtIn, .automatic])
        withExtendedLifetime(observation) {}
    }

    func testPrefersInternalEvenWhenExternalIsPrimary() {
        let screens = [
            ScreenCandidate(id: 4, isBuiltIn: false, hasNotch: false),
            ScreenCandidate(id: 1, isBuiltIn: true, hasNotch: true)
        ]
        XCTAssertEqual(ScreenTarget.preferredIndex(in: screens), 1)
    }

    func testClosedLidSelectsRemainingExternalScreen() {
        let screens = [ScreenCandidate(id: 4, isBuiltIn: false, hasNotch: false)]
        XCTAssertEqual(ScreenTarget.preferredIndex(in: screens), 0)
        XCTAssertNil(ScreenTarget.preferredIndex(in: []))
    }

    func testReopenedInternalBecomesPreferredAgain() {
        let external = ScreenCandidate(id: 4, isBuiltIn: false, hasNotch: false)
        let internalScreen = ScreenCandidate(id: 1, isBuiltIn: true, hasNotch: true)
        XCTAssertEqual(ScreenTarget.preferredIndex(in: [external]), 0)
        XCTAssertEqual(ScreenTarget.preferredIndex(in: [external, internalScreen]), 1)
    }

    // Using the internal screen unconditionally loses the external screen's trigger.
    func testAutomaticHoverChoosesScreenWhoseTopWasEntered() {
        let layouts = hoverLayouts
        XCTAssertEqual(ScreenTarget.hoverIndex(for: .automatic, layouts: layouts,
            pointer: NSPoint(x: 720, y: 895)), 0)
        XCTAssertEqual(ScreenTarget.hoverIndex(for: .automatic, layouts: layouts,
            pointer: NSPoint(x: -960, y: 1195)), 1)
        XCTAssertNil(ScreenTarget.hoverIndex(for: .automatic, layouts: layouts,
            pointer: NSPoint(x: -960, y: 600)))
    }

    func testHoverDoesNotMoveFixedScreenOrPinnedOrActiveInteraction() {
        let point = NSPoint(x: -960, y: 1195)
        XCTAssertNil(ScreenTarget.hoverIndex(for: .display(id: 1, name: "内建"),
            layouts: hoverLayouts, pointer: point))
        XCTAssertNil(ScreenTarget.hoverIndex(for: .automatic, layouts: hoverLayouts,
            pointer: point, pinned: true))
        XCTAssertNil(ScreenTarget.hoverIndex(for: .automatic, layouts: hoverLayouts,
            pointer: point, interactionActive: true))
        XCTAssertNil(ScreenTarget.hoverIndex(for: .automatic, layouts: hoverLayouts,
            pointer: point, excluding: NSRect(x: -980, y: 1180, width: 40, height: 20)))
    }

    func testStackedScreensUseOwningScreenRatherThanExtendedTriggerFromBelow() {
        let layouts = [
            NotchLayout(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), topLeft: nil, topRight: nil),
            NotchLayout(frame: NSRect(x: 0, y: 900, width: 1440, height: 900), topLeft: nil, topRight: nil)
        ]
        XCTAssertNil(ScreenTarget.hoverIndex(for: .automatic, layouts: layouts,
            pointer: NSPoint(x: 720, y: 903)))
        XCTAssertEqual(ScreenTarget.hoverIndex(for: .automatic, layouts: layouts,
            pointer: NSPoint(x: 720, y: 1799)), 1)
        XCTAssertNil(ScreenTarget.hoverIndex(for: .automatic, layouts: [], pointer: .zero))
    }

    private var hoverLayouts: [NotchLayout] {
        [NotchLayout(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            topLeft: NSRect(x: 0, y: 862, width: 640, height: 38),
            topRight: NSRect(x: 800, y: 862, width: 640, height: 38)),
         NotchLayout(frame: NSRect(x: -1920, y: 0, width: 1920, height: 1200),
            topLeft: nil, topRight: nil)]
    }


    func testFullscreenCacheSeparatesDisplaysAndInvalidatesChangedGeometry() {
        var cache = FullscreenHoverCache()
        let now = Date(timeIntervalSince1970: 100)
        let internalFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let externalFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1200)
        cache.store(true, displayID: 1, frame: internalFrame, at: now)
        XCTAssertEqual(cache.value(displayID: 1, frame: internalFrame, at: now), true)
        XCTAssertNil(cache.value(displayID: 4, frame: externalFrame, at: now))
        cache.store(false, displayID: 4, frame: externalFrame, at: now)
        XCTAssertEqual(cache.value(displayID: 4, frame: externalFrame, at: now), false)
        XCTAssertEqual(cache.value(displayID: 1, frame: internalFrame, at: now), true)
        XCTAssertNil(cache.value(displayID: 1, frame: externalFrame, at: now))
        XCTAssertNil(cache.value(displayID: 1, frame: internalFrame, at: now.addingTimeInterval(1)))
    }


    func testLowerScreenCannotRevealThroughTriggerExtensionIntoUpperScreen() {
        let lower = NotchLayout(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), topLeft: nil, topRight: nil)
        XCTAssertFalse(lower.shouldShow(pointer: NSPoint(x: 720, y: 903), visible: false,
            expanded: false, pinned: false, compactSize: .zero, detailSize: .zero))
    }


    func testTopologyRefreshRetainsConnectedScreenUntilItIsRemoved() {
        let internalScreen = ScreenCandidate(id: 1, isBuiltIn: true, hasNotch: true,
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        let external = ScreenCandidate(id: 4, isBuiltIn: false, hasNotch: false,
            frame: NSRect(x: -1920, y: 0, width: 1920, height: 1200))
        let pointer = NSPoint(x: -960, y: 600)
        XCTAssertEqual(ScreenTarget.automaticIndex(in: [internalScreen, external], pointer: pointer), 1)
        XCTAssertEqual(ScreenTarget.automaticIndex(in: [internalScreen, external], pointer: pointer, retaining: 1), 0)
        XCTAssertEqual(ScreenTarget.automaticIndex(in: [external], pointer: pointer, retaining: 1), 0)
        XCTAssertEqual(ScreenTarget.automaticIndex(in: [internalScreen], pointer: pointer, retaining: 4), 0)
        XCTAssertNil(ScreenTarget.automaticIndex(in: [], pointer: pointer, retaining: 1))
    }

    func testExplicitSelectionWinsOverStalePlacementAndKeepsExternalFallback() {
        let builtIn = ScreenCandidate(id: 1, isBuiltIn: true, hasNotch: true, name: "内建",
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        let external = ScreenCandidate(id: 4, isBuiltIn: false, hasNotch: false, name: "Studio Display",
            frame: NSRect(x: -1920, y: 0, width: 1920, height: 1200))
        let screens = [builtIn, external]
        let pointer = NSPoint(x: 960, y: 600)
        XCTAssertEqual(ScreenTarget.resolvedIndex(selection: .display(id: 4, name: "Studio Display"),
            placementID: 1, screens: screens, pointer: pointer), 1, "显式选屏不能被旧放置 ID 覆盖")
        XCTAssertEqual(ScreenTarget.resolvedIndex(selection: .display(id: 99, name: "Studio Display"),
            placementID: nil, screens: screens, pointer: pointer), 1, "ID 变化后应按名字找回外接屏")
        XCTAssertEqual(ScreenTarget.resolvedIndex(selection: .display(id: 99, name: "Old Display"),
            placementID: nil, screens: screens, pointer: pointer), 1, "目标暂时缺失时优先留在外接屏")
        XCTAssertEqual(ScreenTarget.resolvedIndex(selection: .automatic,
            placementID: 1, screens: screens, pointer: NSPoint(x: -960, y: 600)), 0,
            "自动模式应保留上次放置的屏幕")
        XCTAssertEqual(ScreenTarget.resolvedIndex(selection: .automatic, placementID: 99,
            placementName: "Studio Display", screens: screens, pointer: NSPoint(x: 960, y: 600)), 1,
            "自动模式在 ID 失效时应按名字续上原屏幕")
    }

    @MainActor
    func testReconcileScreenSelectionHealsStaleIDByDisplayName() throws {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let displayID = ScreenTarget.displayID(of: screen)
        let settings = IslandSettings(defaults: defaults)
        settings.screenSelection = .display(id: displayID &+ 1, name: screen.localizedName)
        settings.reconcileScreenSelection(in: [screen])
        XCTAssertEqual(settings.screenSelection.displayID, displayID)
        XCTAssertEqual(settings.screenSelection.displayName, screen.localizedName)
        XCTAssertTrue(ScreenTarget.matches(settings.screenSelection, screen: screen))
    }

    func testExactTopEdgeRevealsNotchedAndExternalScreens() {
        let layouts = hoverLayouts
        for (index, point) in [(0, NSPoint(x: 720, y: 900)), (1, NSPoint(x: -960, y: 1200))] {
            XCTAssertTrue(layouts[index].shouldShow(pointer: point, visible: false,
                expanded: false, pinned: false, compactSize: .zero, detailSize: .zero))
            XCTAssertEqual(ScreenTarget.hoverIndex(for: .automatic, layouts: layouts, pointer: point), index)
        }
    }

    func testTopEdgeInitialScreenSelectionUsesPointerInsteadOfBuiltInFallback() {
        let screens = [
            ScreenCandidate(id: 1, isBuiltIn: true, hasNotch: true,
                frame: NSRect(x: 0, y: 0, width: 1440, height: 900)),
            ScreenCandidate(id: 4, isBuiltIn: false, hasNotch: false,
                frame: NSRect(x: -1920, y: 0, width: 1920, height: 1200))
        ]
        XCTAssertEqual(ScreenTarget.automaticIndex(in: screens,
            pointer: NSPoint(x: -960, y: 1200)), 1)
    }

    func testSharedTopEdgeBelongsToUpperScreenAndDoesNotRevealLowerPanel() {
        let lower = NotchLayout(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), topLeft: nil, topRight: nil)
        let upper = NotchLayout(frame: NSRect(x: 0, y: 900, width: 1440, height: 900), topLeft: nil, topRight: nil)
        let point = NSPoint(x: 720, y: 900)
        for layouts in [[lower, upper], [upper, lower]] {
            XCTAssertNil(ScreenTarget.hoverIndex(for: .automatic, layouts: layouts, pointer: point))
            var hover = IslandHoverState()
            XCTAssertFalse(hover.shouldShow(in: lower, pointer: point, mode: .hidden,
                pinned: false, compactSize: .zero, detailSize: .zero, excluding: nil,
                screenFrames: layouts.map(\.screenFrame)))
            hover.reset()
        }
        XCTAssertEqual(ScreenTarget.hoverIndex(for: .automatic, layouts: [lower], pointer: point), 0)
    }

}
