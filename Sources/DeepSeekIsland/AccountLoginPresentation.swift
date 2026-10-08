import AppKit

/// A system-browser authorization must be able to cover the app's normally elevated windows.
@MainActor
final class BrowserAuthorizationWindowLevels {
    private struct SavedLevel {
        weak var window: NSWindow?
        let level: NSWindow.Level
    }
    private var saved: [SavedLevel] = []
    private(set) var isActive = false

    func update(active: Bool, windows: [NSWindow]) {
        if active {
            isActive = true
            saved.removeAll { $0.window == nil }
            for window in windows where !saved.contains(where: { $0.window === window }) {
                saved.append(SavedLevel(window: window, level: window.level))
                window.level = .normal
            }
        } else {
            guard isActive else { return }
            isActive = false
            for entry in saved { entry.window?.level = entry.level }
            saved.removeAll()
        }
    }
}
