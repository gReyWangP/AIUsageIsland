import AppKit

/// 各屏幕分别限频；几何变化不复用旧的全屏判定。
struct FullscreenHoverCache {
    private struct Entry {
        let frame: CGRect
        let checkedAt: Date
        let fullscreen: Bool
    }
    private var entries: [UInt32: Entry] = [:]

    func value(displayID: UInt32, frame: CGRect, at now: Date) -> Bool? {
        guard let entry = entries[displayID], entry.frame == frame,
              now.timeIntervalSince(entry.checkedAt) < 1 else { return nil }
        return entry.fullscreen
    }

    mutating func store(_ value: Bool, displayID: UInt32, frame: CGRect, at now: Date) {
        entries[displayID] = Entry(frame: frame, checkedAt: now, fullscreen: value)
    }
}

@MainActor
final class FullscreenHoverPolicy {
    private var cache = FullscreenHoverCache()
    static func coversScreen(window: CGRect, screen: CGRect) -> Bool {
        abs(window.minX - screen.minX) <= 2 && abs(window.minY - screen.minY) <= 2
            && abs(window.width - screen.width) <= 2 && abs(window.height - screen.height) <= 2
    }
    func isFullscreen(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        let now = Date.now
        let displayID = ScreenTarget.displayID(of: screen)
        if let cached = cache.value(displayID: displayID, frame: screen.frame, at: now) { return cached }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            cache.store(false, displayID: displayID, frame: screen.frame, at: now)
            return false
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let quartzScreen = CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                                  width: screen.frame.width, height: screen.frame.height)
        let fullscreen = windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return Self.coversScreen(window: rect, screen: quartzScreen)
        }
        cache.store(fullscreen, displayID: displayID, frame: screen.frame, at: now)
        return fullscreen
    }
}
