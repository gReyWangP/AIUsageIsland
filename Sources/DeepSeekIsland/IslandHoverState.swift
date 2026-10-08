import AppKit

/// 记录一次离开过程；原有触发区与可见内容的停留区分别判断。
struct IslandHoverState {
    private(set) var outsideSince: Date?
    static let hideDelay: TimeInterval = 0.5

    mutating func reset() { outsideSince = nil }

    func shouldShow(in layout: NotchLayout, pointer: NSPoint,
                    mode: IslandPresentation.Mode, pinned: Bool,
                    compactSize: CGSize, detailSize: CGSize,
                    excluding excludedRect: NSRect?, screenFrames: [NSRect]? = nil) -> Bool {
        // 一旦离开，0.5 秒仅用于延迟收起，不能让两侧旧数据区取消收起。
        // 隐藏动画中的 NSPanel 仍在屏幕上，但不代表其停留区仍有效。
        layout.shouldShow(pointer: pointer, visible: mode != .hidden && outsideSince == nil,
                          expanded: mode == .expanded, pinned: pinned,
                          compactSize: compactSize, detailSize: detailSize,
                          excluding: excludedRect, screenFrames: screenFrames)
    }

    mutating func shouldHide(pointerInside: Bool, at now: Date, holdingPopover: Bool = false) -> Bool {
        if holdingPopover { reset(); return false }
        if pointerInside { reset(); return false }
        if outsideSince == nil { outsideSince = now }
        guard let outsideSince, now.timeIntervalSince(outsideSince) > Self.hideDelay else { return false }
        reset()
        return true
    }
}
