import AppKit
import SwiftUI

private final class MenuBarCardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Uses the island's background instead of NSPopover's unconditional system material.
@MainActor
final class MenuBarPopoverController: NSObject {
    private let panel: MenuBarCardPanel
    private var escapeMonitor: Any?
    private var hosting: NSHostingController<MenuBarPopoverView>?
    private weak var anchor: NSView?
    var onClose: (() -> Void)?
    var isVisible: Bool { panel.isVisible }
    var screenFrame: NSRect? { isVisible ? panel.frame : nil }

    override init() {
        panel = MenuBarCardPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    func show(_ view: MenuBarPopoverView, relativeTo anchor: NSView, appearance: NSAppearance?) {
        guard anchor.window?.isVisible == true else { return }
        self.anchor = anchor
        update(view, appearance: appearance)
        panel.orderFrontRegardless()
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard event.keyCode == 53, self?.isVisible == true else { return false }
                    self?.close()
                    return true
                }
                return handled ? nil : event
            }
        }
    }
    func update(_ view: MenuBarPopoverView, appearance: NSAppearance?) {
        if let hosting { hosting.rootView = view }
        else {
            let hosting = NSHostingController(rootView: view)
            self.hosting = hosting
            panel.contentViewController = hosting
        }
        panel.appearance = appearance
        hosting?.view.appearance = appearance
        hosting?.view.layoutSubtreeIfNeeded()
        guard let size = hosting?.view.fittingSize, size.width > 0, size.height > 0 else { return }
        position(size: size)
    }
    /// The panel must track status-item movement even when account data is unchanged.
    func reposition() {
        guard isVisible else { return }
        position(size: panel.frame.size)
    }
    private func position(size: NSSize) {
        guard let anchor, let window = anchor.window else { return }
        let icon = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) }
            ?? window.screen
        guard let screen else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = max(bounds.minX, min(icon.midX - size.width / 2, bounds.maxX - size.width))
        let y = max(bounds.minY, min(icon.minY - 6 - size.height, bounds.maxY - size.height))
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
    func focus() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    func close() {
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if wasVisible { onClose?() }
    }
}
