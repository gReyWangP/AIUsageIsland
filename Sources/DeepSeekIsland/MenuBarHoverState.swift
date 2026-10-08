import Foundation

/// Hover previews and click-held cards share timing, but never share the central island trigger.
struct MenuBarHoverState {
    enum Mode { case hidden, preview, pinned }
    private(set) var mode: Mode = .hidden
    private var enteredAt: Date?
    private var leftAt: Date?
    private var suppressedUntilExit = false

    mutating func update(iconInside: Bool, cardInside: Bool, enabled: Bool, available: Bool, at now: Date) {
        guard available else { dismiss(); return }
        if !iconInside && !cardInside { suppressedUntilExit = false }
        guard mode != .pinned else { return }
        guard enabled else { dismiss(); return }
        if mode == .preview {
            if iconInside || cardInside { leftAt = nil }
            else {
                if leftAt == nil { leftAt = now }
                if let leftAt, now.timeIntervalSince(leftAt) >= 0.4 { dismiss() }
            }
        } else if iconInside && !suppressedUntilExit {
            if enteredAt == nil { enteredAt = now }
            if let enteredAt, now.timeIntervalSince(enteredAt) >= 0.3 {
                mode = .preview
                leftAt = nil
            }
        } else { enteredAt = nil }
    }

    mutating func togglePinned() {
        if mode == .pinned { dismiss() }
        else { mode = .pinned; enteredAt = nil; leftAt = nil }
    }

    mutating func dismiss() {
        mode = .hidden
        enteredAt = nil
        leftAt = nil
        suppressedUntilExit = true
    }
}
