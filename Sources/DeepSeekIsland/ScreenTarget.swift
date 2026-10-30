import AppKit
import CoreGraphics
import Combine

struct ScreenCandidate {
    let id: CGDirectDisplayID
    let isBuiltIn: Bool
    let hasNotch: Bool
    var name: String = ""
    var frame: NSRect = .zero
}

enum ScreenTarget {
    /// 统一订阅显示器选择，让切屏操作使用订阅对应的选择。
    @MainActor
    static func observeSelection(of settings: IslandSettings,
                                 perform: @escaping @MainActor (ScreenSelection) -> Void) -> AnyCancellable {
        // @Published 在 willSet 阶段发送；此处重新读取属性会落后一轮。
        settings.$screenSelection.sink { selection in
            MainActor.assumeIsolated { perform(selection) }
        }
    }


    /// 鼠标不在任何屏幕时的回退优先级：带刘海的内建屏 > 内建屏 > 第一块。
    static func preferredIndex(in screens: [ScreenCandidate]) -> Int? {
        if let notched = screens.firstIndex(where: { $0.isBuiltIn && $0.hasNotch }) { return notched }
        if let builtIn = screens.firstIndex(where: \.isBuiltIn) { return builtIn }
        return screens.isEmpty ? nil : 0
    }

    /// 先按实际屏幕内部归属；无屏幕包含时，允许精确落在最顶边。
    /// 上下相接的边界属于上方屏幕，不能唤出下方浮窗。
    static func pointerIndex(in frames: [NSRect], pointer: NSPoint) -> Int? {
        if let index = frames.firstIndex(where: { $0.contains(pointer) }) { return index }
        return frames.firstIndex { frame in
            frame.width > 0 && frame.height > 0 && pointer.y == frame.maxY
                && pointer.x >= frame.minX && pointer.x < frame.maxX
        }
    }

    /// 拓扑变化保留仍连接的当前屏幕；首次定位或目标断开时按鼠标回退。
    static func automaticIndex(in screens: [ScreenCandidate], pointer: NSPoint,
                               retaining currentDisplayID: UInt32? = nil) -> Int? {
        if let currentDisplayID,
           let index = screens.firstIndex(where: { $0.id == currentDisplayID }) { return index }
        return pointerIndex(in: screens.map(\.frame), pointer: pointer) ?? preferredIndex(in: screens)
    }

    static func preferredScreen(in screens: [NSScreen]) -> NSScreen? {
        guard let index = preferredIndex(in: candidates(in: screens)) else { return nil }
        return screens[index]
    }

    /// 按用户选择挑屏幕。
    ///
    /// 显式选择优先于悬浮窗上次拖到的屏幕：显示器重新配置时 ID 可能暂时失效，
    /// 先按名字找回同一块屏，再退到任意外接屏，最后才回退内建屏。
    /// 自动模式则保留上次的位置（ID 失效时用名字续上）。
    static func screen(for selection: ScreenSelection, in screens: [NSScreen],
                       retaining currentDisplayID: UInt32? = nil,
                       placementID: UInt32? = nil,
                       placementName: String? = nil) -> NSScreen? {
        guard let index = resolvedIndex(selection: selection, placementID: placementID,
            placementName: placementName, screens: candidates(in: screens),
            pointer: NSEvent.mouseLocation, retaining: currentDisplayID) else { return nil }
        return screens[index]
    }

    static func resolvedIndex(selection: ScreenSelection, placementID: UInt32?,
                              placementName: String? = nil,
                              screens: [ScreenCandidate], pointer: NSPoint,
                              retaining currentDisplayID: UInt32? = nil) -> Int? {
        switch selection {
        case .automatic:
            if let placementID,
               let index = screens.firstIndex(where: { $0.id == placementID }) { return index }
            if let placementName, !placementName.isEmpty,
               let index = screens.firstIndex(where: { $0.name == placementName }) { return index }
            return automaticIndex(in: screens, pointer: pointer, retaining: currentDisplayID)
        case .display(let id, let name):
            if let index = screens.firstIndex(where: { $0.id == id }) { return index }
            if !name.isEmpty,
               let index = screens.firstIndex(where: { $0.name == name }) { return index }
            if let index = screens.firstIndex(where: { !$0.isBuiltIn }) { return index }
            return preferredIndex(in: screens)
        }
    }

    static func matches(_ selection: ScreenSelection, screen: NSScreen) -> Bool {
        switch selection {
        case .automatic: return true
        case .display(let id, let name):
            return displayID(of: screen) == id
                || (!name.isEmpty && screen.localizedName == name)
        }
    }

    /// 只有进入所属屏幕的顶部触发区才切屏，普通移动和交互期间不搬动浮窗。
    static func hoverIndex(for selection: ScreenSelection, layouts: [NotchLayout],
                           pointer: NSPoint, pinned: Bool = false,
                           interactionActive: Bool = false,
                           excluding excludedRect: NSRect? = nil) -> Int? {
        guard selection == .automatic, !pinned, !interactionActive else { return nil }
        let frames = layouts.map(\.screenFrame)
        guard let index = pointerIndex(in: frames, pointer: pointer),
              layouts[index].shouldShow(pointer: pointer, visible: false, expanded: false,
                pinned: false, compactSize: .zero, detailSize: .zero,
                excluding: excludedRect, screenFrames: frames) else { return nil }
        return index
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }

    static func candidates(in screens: [NSScreen]) -> [ScreenCandidate] {
        screens.map { screen in
            let id = displayID(of: screen)
            return ScreenCandidate(
                id: id,
                isBuiltIn: id != 0 && CGDisplayIsBuiltin(id) != 0,
                hasNotch: screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil,
                name: screen.localizedName,
                frame: screen.frame
            )
        }
    }
}
