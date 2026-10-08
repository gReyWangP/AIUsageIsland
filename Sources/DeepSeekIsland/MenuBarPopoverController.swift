import AppKit
import SwiftUI

@MainActor
final class MenuBarPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var escapeMonitor: Any?
    private var hosting: NSHostingController<MenuBarPopoverView>?
    var onClose: (() -> Void)?
    var isVisible: Bool { popover.isShown }
    var screenFrame: NSRect? { isVisible ? hosting?.view.window?.frame : nil }

    override init() {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
    }
    func show(_ view: MenuBarPopoverView, relativeTo anchor: NSView, appearance: NSAppearance?) {
        guard anchor.window?.isVisible == true else { return }
        update(view, appearance: appearance)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if popover.isShown && escapeMonitor == nil {
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
            popover.contentViewController = hosting
        }
        popover.appearance = appearance
        hosting?.view.appearance = appearance
        hosting?.view.layoutSubtreeIfNeeded()
        if let size = hosting?.view.fittingSize { popover.contentSize = size }
    }
    func focus() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        hosting?.view.window?.makeKeyAndOrderFront(nil)
    }
    func close() { popover.performClose(nil) }
    func popoverDidClose(_ notification: Notification) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        onClose?()
    }
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }
}
