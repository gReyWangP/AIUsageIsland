import AppKit

/// 悬浮窗的**锚点与触发策略**。
///
/// 这里刻意不再计算面板尺寸：尺寸由 `IslandView` 实测后上报，面板照着设 frame。
/// 旧版让 `NotchLayout` 按 `dual` 猜尺寸，结果判定区（按「是否都已登录」）和
/// 卡片（按「是否已启用两个平台」）用了不同条件，鼠标明明在卡片上却被判为离开。
/// 现在判定区就是面板 frame、面板 frame 就是实测内容尺寸——这类错位不可能再发生。
struct NotchLayout {
    let screenFrame: NSRect
    let hasNotch: Bool
    /// 摄像头开口区域，用于触发和点击。
    let triggerRect: NSRect
    let screenTop: CGFloat
    /// 面板水平中心，始终与刘海（或屏幕）中心对齐。
    let anchorCenterX: CGFloat
    let bandHeight: CGFloat
    let wingWidth: CGFloat
    let notchWidth: CGFloat

    static let preferredWingWidth: CGFloat = 190
    /// 外接屏上悬浮条的固定宽度。
    static let externalBarWidth: CGFloat = 565

    /// 横向悬浮条的总宽度：刘海 + 两侧翅膀；外接屏用固定宽度。
    var horizontalBarWidth: CGFloat {
        hasNotch ? notchWidth + 2 * wingWidth : Self.externalBarWidth
    }

    /// 详情顶部内边距：刘海屏要让开摄像头区域，外接屏不需要。
    var topInset: CGFloat { hasNotch ? bandHeight + 9 : 14 }

    /// 悬浮条矩形：水平居中、贴着屏幕顶边。
    func compactFrame(size: CGSize) -> NSRect {
        NSRect(x: anchorCenterX - size.width / 2, y: screenTop - size.height,
               width: size.width, height: size.height)
    }

    /// 详情面板矩形：同样水平居中、贴着屏幕顶边，只是更高。
    func detailFrame(size: CGSize) -> NSRect {
        NSRect(x: anchorCenterX - size.width / 2, y: screenTop - size.height,
               width: size.width, height: size.height)
    }

    /// 鼠标是否仍应停留在展开态。
    func shouldShow(pointer: NSPoint,
                    visible: Bool,
                    expanded: Bool,
                    pinned: Bool,
                    compactSize: CGSize,
                    detailSize: CGSize,
                    excluding excludedRect: NSRect? = nil,
                    screenFrames: [NSRect]? = nil) -> Bool {
        if pinned { return true }
        // 最顶边可触发，但上下相接的屏幕边界优先归属实际包含鼠标的屏幕。
        let frames = screenFrames ?? [screenFrame]
        guard let index = ScreenTarget.pointerIndex(in: frames, pointer: pointer),
              frames[index] == screenFrame else { return false }
        if let excludedRect, excludedRect.contains(pointer) { return false }
        // 刘海整块都是触发区；兼容边距由所属屏幕边界裁剪。
        let trigger = hasNotch
            ? NSRect(x: triggerRect.minX, y: triggerRect.minY,
                     width: triggerRect.width, height: triggerRect.height + 8)
            : triggerRect
        if trigger.contains(pointer) { return true }
        if visible && compactFrame(size: compactSize).contains(pointer) { return true }
        if expanded && detailFrame(size: detailSize).contains(pointer) { return true }
        return false
    }

    /// 摄像头遮挡区域的点击是否由本应用处理。
    func acceptsCameraClick(_ point: NSPoint) -> Bool {
        hasNotch && triggerRect.contains(point)
    }

    init(frame: NSRect, topLeft: NSRect?, topRight: NSRect?) {
        screenFrame = frame
        screenTop = frame.maxY
        if let topLeft, let topRight,
           topRight.minX > topLeft.maxX,
           topLeft.minY == topRight.minY {
            hasNotch = true
            triggerRect = NSRect(
                x: topLeft.maxX,
                y: topLeft.minY,
                width: topRight.minX - topLeft.maxX,
                height: min(topLeft.height, topRight.height)
            )
            notchWidth = triggerRect.width
            bandHeight = triggerRect.height
            anchorCenterX = triggerRect.midX
            wingWidth = min(Self.preferredWingWidth,
                            max(120, (frame.width - triggerRect.width) / 2 - 12))
        } else {
            hasNotch = false
            notchWidth = 0
            bandHeight = 38
            anchorCenterX = frame.midX
            wingWidth = Self.preferredWingWidth
            triggerRect = NSRect(x: frame.midX - Self.externalBarWidth / 2,
                                 y: screenTop - bandHeight,
                                 width: Self.externalBarWidth,
                                 height: bandHeight + 8)
        }
    }

    init(screen: NSScreen) {
        self.init(frame: screen.frame,
                  topLeft: screen.auxiliaryTopLeftArea,
                  topRight: screen.auxiliaryTopRightArea)
    }
}
