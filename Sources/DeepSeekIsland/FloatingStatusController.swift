import AppKit
import SwiftUI
import QuartzCore

@MainActor
final class FloatingStatusSurface: ObservableObject {
    @Published var collapsed = false
    @Published var horizontal = false
    @Published var expandedSize = CGSize(width: 62, height: 164)
}

@MainActor
final class FloatingStatusController {
    private let model: IslandModel
    private let settings: IslandSettings
    private let panel: NSPanel
    private let card = MenuBarPopoverController()
    private var host: NSHostingView<FloatingStatusView>?
    private var dragState: FloatingStatusDrag?
    private var dragTimer: Timer?
    private struct SideDockDragState { let grabOffset: CGFloat }
    private var sideDockDrag: SideDockDragState?
    private var sideDockDragPosition: CGFloat?
    private var selected: UsagePlatform?
    private var selectedAccount: AccountReference?
    private let fullscreenPolicy = FullscreenHoverPolicy()
    private var lastScreenSelection: ScreenSelection
    private var lastCardUpdate = Date.distantPast
    private let surface = FloatingStatusSurface()
    private var interaction = FloatingStatusInteraction()
    private var hover = MenuBarHoverState()
    private var hoveredPlatform: UsagePlatform?
    private var iconAnchors: [UsagePlatform: NSView] = [:]
    private var targetFrame: CGRect?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    var onSettings: (() -> Void)?

    init(model: IslandModel, settings: IslandSettings) {
        self.model = model; self.settings = settings
        lastScreenSelection = settings.screenSelection
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = FloatingStatusView(model: model, settings: settings, surface: surface,
            onSelect: { [weak self] in self?.select($0) },
            onSettings: { [weak self] in self?.onSettings?() },
            onDrag: { [weak self] ended in self?.drag(to: NSEvent.mouseLocation, ended: ended) },
            onAnchor: { [weak self] platform, view in self?.iconAnchors[platform] = view },
            onHover: { [weak self] platform, inside in
                guard let self, self.dragState == nil, self.sideDockDrag == nil else { return }
                if inside { self.hoveredPlatform = platform }
                else if self.hoveredPlatform == platform { self.hoveredPlatform = nil }
            })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []; host.autoresizingMask = [.width, .height]
        panel.contentView = host; self.host = host
        card.onClose = { [weak self] in
            self?.hover.dismiss()
            self?.selected = nil
            self?.selectedAccount = nil
            self?.model.notificationDetailAccount = nil
            self?.model.detailFocus = nil
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissOutside() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissOutside() }
            return event
        }
    }
    func stop() {
        dragTimer?.invalidate(); dragTimer = nil; dragState = nil
        sideDockDrag = nil; sideDockDragPosition = nil
        panel.orderOut(nil); card.close()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }
    private var platforms: [UsagePlatform] {
        if settings.sideDockEnabled { return model.visiblePlatforms }
        return settings.orderedPlatforms.filter { model.platformAccounts.enabled.contains($0) }
    }
    private func screen() -> NSScreen? {
        let placement = settings.floatingStatusPlacement
        if let id = placement.displayID, let screen = NSScreen.screens.first(where: { ScreenTarget.displayID(of: $0) == id }) { return screen }
        return ScreenTarget.screen(for: settings.screenSelection, in: NSScreen.screens)
    }
    func closeDetails() { hover.dismiss(); card.close() }
    private func reveal() {
        interaction.reveal()
        surface.collapsed = false
        update()
    }
    func toggleDetails() {
        if card.isVisible { closeDetails() } else { showDetails() }
    }
    func showDetails(account: AccountReference? = nil) {
        reveal()
        hover = MenuBarHoverState()
        hover.togglePinned()
        if let account, model.savedAccounts.contains(account) {
            selectedAccount = account
            selected = account.platform
            refreshCard(show: true)
            return
        }
        selectedAccount = nil
        if let platform = platforms.first(where: { $0 == settings.menuBarPlatform }) ?? platforms.first {
            selected = platform
            refreshCard(show: true)
        } else { onSettings?() }
    }
    func update(suspended: Bool = false, pointer: NSPoint? = nil, at now: Date = .now) {
        if lastScreenSelection != settings.screenSelection {
            lastScreenSelection = settings.screenSelection
            var placement = settings.floatingStatusPlacement
            placement.displayID = ScreenTarget.screen(for: settings.screenSelection, in: NSScreen.screens).map { ScreenTarget.displayID(of: $0) }
            settings.floatingStatusPlacement = placement
        }
        guard settings.floatingStatusEnabled, !model.isSleeping, !suspended, let screen = screen() else {
            dragTimer?.invalidate(); dragTimer = nil; dragState = nil
            sideDockDrag = nil; sideDockDragPosition = nil
            panel.orderOut(nil); card.close(); targetFrame = nil; return
        }
        if settings.pausesHoverInFullscreen, fullscreenPolicy.isFullscreen(on: screen) {
            dragTimer?.invalidate(); dragTimer = nil; dragState = nil
            sideDockDrag = nil; sideDockDragPosition = nil
            panel.orderOut(nil); card.close(); targetFrame = nil; return
        }
        let visiblePlatforms = platforms
        if let platform = selected, !visiblePlatforms.contains(platform) {
            selected = nil
            selectedAccount = nil
            if card.isVisible { card.close() }
        }
        if let hoveredPlatform, !visiblePlatforms.contains(hoveredPlatform) {
            self.hoveredPlatform = nil
        }
        panel.hasShadow = !settings.sideDockEnabled
        let point = pointer ?? NSEvent.mouseLocation
        var placement = settings.floatingStatusPlacement
        if settings.sideDockEnabled {
            placement.edge = settings.sideDockOnLeft ? .left : .right
            placement.y = 0.5
        }
        let expanded = settings.sideDockEnabled
            ? SideDockLayout.frame(in: screen.visibleFrame, count: platforms.count, onLeft: settings.sideDockOnLeft,
                                   verticalPosition: sideDockDragPosition ?? CGFloat(settings.sideDockY))
            : FloatingStatusLayout.frame(edge: placement.edge, position: CGPoint(x: placement.x, y: placement.y), in: screen.visibleFrame, count: platforms.count)
        if dragState == nil {
            if surface.expandedSize != expanded.size { surface.expandedSize = expanded.size }
            if surface.horizontal != (placement.edge == .top) { surface.horizontal = placement.edge == .top }
        }
        // Use only the currently visible frame: invisible icons cannot keep a tucked bar open.
        let insideBar = panel.isVisible && panel.frame.contains(point)
        let insideCard = card.screenFrame?.contains(point) == true
        // The reveal strip remains a valid trigger after expansion. The full bar
        // is inset from the edge, so a stationary pointer at the screen edge otherwise falls
        // outside it and starts an endless collapse/reveal cycle.
        let trigger = FloatingStatusLayout.collapsedFrame(expanded: expanded, edge: placement.edge, screen: screen.visibleFrame)
        let insideEdgeTrigger = panel.isVisible && placement.edge != .free && trigger.contains(point)
        hover.update(iconInside: hoveredPlatform != nil && insideBar,
                     cardInside: insideCard, enabled: dragState == nil && sideDockDrag == nil && !surface.collapsed,
                     available: true, at: now)
        if hover.mode == .preview, sideDockDrag == nil, let platform = hoveredPlatform, insideBar,
           selected != platform || !card.isVisible {
            selectedAccount = nil; selected = platform
            refreshCard(show: true)
        } else if hover.mode == .hidden && card.isVisible { card.close() }
        interaction.update(insideBar: insideBar || insideEdgeTrigger, insideCard: card.isVisible,
                           docked: placement.edge != .free && settings.floatingStatusAutoHides,
                           dragging: dragState != nil || sideDockDrag != nil, at: now)
        if surface.collapsed && !interaction.collapsed { hover = MenuBarHoverState() }
        if surface.collapsed != interaction.collapsed { surface.collapsed = interaction.collapsed }
        if dragState == nil && sideDockDrag == nil {
            let wanted = interaction.collapsed
                ? FloatingStatusLayout.collapsedFrame(expanded: expanded, edge: placement.edge, screen: screen.visibleFrame)
                : expanded
            move(to: wanted, animated: panel.isVisible)
        }
        if dragState == nil, settings.floatingStatusPlacement.displayID != ScreenTarget.displayID(of: screen) {
            var placement = settings.floatingStatusPlacement
            placement.displayID = ScreenTarget.displayID(of: screen)
            settings.floatingStatusPlacement = placement
        }
        if panel.appearance?.name != settings.appearanceMode.nsAppearance?.name {
            panel.appearance = settings.appearanceMode.nsAppearance
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        card.reposition()
        if selected != nil, Date().timeIntervalSince(lastCardUpdate) >= 1 { refreshCard() }
    }
    private func move(to frame: CGRect, animated: Bool) {
        guard targetFrame != frame else { return }
        targetFrame = frame
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
        card.reposition()
    }
    func drag(to point: NSPoint, ended: Bool) {
        if settings.sideDockEnabled {
            dragSideDock(to: point, ended: ended)
            return
        }
        let now = Date.now
        if dragState == nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().setFrame(panel.frame, display: true)
            }
            if surface.collapsed {
                var expanded = panel.frame
                expanded.size = surface.expandedSize
                panel.setFrame(expanded, display: true)
            }
            dragState = FloatingStatusDrag(frame: panel.frame, pointer: point,
                                           edge: settings.floatingStatusPlacement.edge)
            interaction.reveal(); surface.collapsed = false
            hoveredPlatform = nil; hover.dismiss(); card.close()
            targetFrame = nil
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.renderDrag(at: .now) }
            }
            RunLoop.main.add(timer, forMode: .common)
            dragTimer = timer
        }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? panel.screen ?? self.screen()
        guard let screen, var state = dragState else { return }
        state.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
        state.update(pointer: point, in: screen.visibleFrame, count: platforms.count, at: now)
        dragState = state
        if surface.expandedSize != state.targetSize { surface.expandedSize = state.targetSize }
        if surface.horizontal != (state.edge == .top) { surface.horizontal = state.edge == .top }
        renderDrag(at: now)
        guard ended else { return }
        dragTimer?.invalidate(); dragTimer = nil
        dragState = nil
        let proposed = state.targetFrame()
        let settled = FloatingStatusLayout.settle(frame: proposed, in: screen.visibleFrame, count: platforms.count)
        let edge = state.edge == .free ? settled.edge : state.edge
        let size = FloatingStatusLayout.size(edge: edge, count: platforms.count, bounds: screen.visibleFrame)
        let position = FloatingStatusLayout.normalized(origin: proposed.origin, size: size, in: screen.visibleFrame)
        let frame = FloatingStatusLayout.frame(edge: edge, position: position, in: screen.visibleFrame, count: platforms.count)
        surface.expandedSize = size
        surface.horizontal = edge == .top
        settings.floatingStatusPlacement = FloatingStatusPlacement(edge: edge, x: position.x, y: position.y, displayID: ScreenTarget.displayID(of: screen))
        interaction.reveal()
        move(to: frame, animated: true)
    }
    private func dragSideDock(to point: NSPoint, ended: Bool) {
        guard let screen = panel.screen ?? screen() else { return }
        let visible = screen.visibleFrame
        let size = SideDockLayout.frame(in: visible, count: platforms.count, onLeft: settings.sideDockOnLeft,
                                        verticalPosition: sideDockDragPosition ?? CGFloat(settings.sideDockY)).size
        if sideDockDrag == nil {
            dragTimer?.invalidate(); dragTimer = nil
            dragState = nil
            let position = sideDockPosition(in: visible)
            let frame = SideDockLayout.frame(in: visible, count: platforms.count, onLeft: settings.sideDockOnLeft,
                                             verticalPosition: position)
            panel.setFrame(frame, display: true)
            sideDockDragPosition = position
            sideDockDrag = SideDockDragState(grabOffset: point.y - frame.midY)
            interaction.reveal(); surface.collapsed = false
            hoveredPlatform = nil; hover.dismiss(); card.close()
            targetFrame = frame
        }
        guard let state = sideDockDrag else { return }
        let available = max(0, visible.height - size.height)
        let top = min(visible.maxY - size.height,
                      max(visible.minY, point.y - state.grabOffset - size.height / 2))
        let position = available > 0 ? min(1, max(0, (top - visible.minY) / available)) : 0.5
        sideDockDragPosition = position
        let frame = SideDockLayout.frame(in: visible, count: platforms.count, onLeft: settings.sideDockOnLeft,
                                         verticalPosition: position)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        targetFrame = frame
        card.reposition()
        guard ended else { return }
        sideDockDrag = nil
        sideDockDragPosition = nil
        settings.sideDockY = Double(position)
        interaction.reveal()
        targetFrame = nil
        move(to: frame, animated: false)
    }
    private func sideDockPosition(in visible: CGRect) -> CGFloat {
        let size = SideDockLayout.frame(in: visible, count: platforms.count, onLeft: settings.sideDockOnLeft,
                                        verticalPosition: 0).size
        let available = max(0, visible.height - size.height)
        return available > 0 ? min(1, max(0, (panel.frame.minY - visible.minY) / available)) : 0.5
    }
    private func renderDrag(at now: Date) {
        guard let state = dragState else { return }
        // Position follows the pointer immediately; only size interpolates. This
        // avoids restarting a window-position animation on every mouse event.
        let frame = state.frame(at: now)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
    private func select(_ platform: UsagePlatform) {
        if selected == platform, card.isVisible, hover.mode == .pinned { closeDetails(); return }
        interaction.reveal(); surface.collapsed = false
        hover = MenuBarHoverState(); hover.togglePinned()
        selectedAccount = nil
        selected = platform; refreshCard(show: true)
    }
    private func refreshCard(show: Bool = false) {
        guard let platform = selected, let host,
              platforms.contains(platform) || selectedAccount.map({ model.savedAccounts.contains($0) }) == true else { card.close(); return }
        let source = model.menuBarSource(for: platform, account: selectedAccount)
        var view = MenuBarPopoverView(model: model, settings: settings, source: source,
            canRefresh: !source.isRefreshing,
            onRefresh: { Task { await source.refresh(platform) } },
            onAnalysis: { [weak self] in
                guard let self else { return }
                UsageAnalysisWindowController.shared.show(model: self.model, account: source.account)
            },
            onSettings: { [weak self] in self?.card.close(); self?.onSettings?() },
            onClose: { [weak self] in self?.card.close() })
        view.sideDockCallout = settings.sideDockEnabled
        view.calloutPointsLeft = settings.sideDockOnLeft
        let edge = settings.sideDockEnabled ? (settings.sideDockOnLeft ? FloatingStatusEdge.left : .right) : settings.floatingStatusPlacement.edge
        let freeOpensRight = panel.frame.midX < (panel.screen?.visibleFrame.midX ?? panel.frame.midX)
        card.preferredEdge = edge == .left ? .maxX : edge == .right ? .minX : edge == .free ? (freeOpensRight ? .maxX : .minX) : nil
        if show { card.show(view, relativeTo: settings.sideDockEnabled ? (iconAnchors[platform] ?? host) : host, appearance: settings.appearanceMode.nsAppearance) }
        else { card.update(view, appearance: settings.appearanceMode.nsAppearance) }
        lastCardUpdate = .now
    }
    private func dismissOutside() {
        let point = NSEvent.mouseLocation
        if !panel.frame.contains(point), card.screenFrame?.contains(point) != true { card.close() }
    }
}

struct FloatingStatusView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    @ObservedObject var surface: FloatingStatusSurface
    let onSelect: (UsagePlatform) -> Void
    let onSettings: () -> Void
    let onDrag: (Bool) -> Void
    let onAnchor: (UsagePlatform, NSView) -> Void
    let onHover: (UsagePlatform, Bool) -> Void
    private var platforms: [UsagePlatform] {
        if settings.sideDockEnabled { return model.visiblePlatforms }
        return settings.orderedPlatforms.filter { model.platformAccounts.enabled.contains($0) }
    }
    var body: some View {
        let horizontal = surface.horizontal
        let layout = FloatingStatusFlowLayout(itemHeight: settings.sideDockEnabled ? SideDockLayout.itemHeight : 48, progress: horizontal ? 1 : 0)
        GeometryReader { geometry in
        ZStack {
        ScrollView(horizontal ? .horizontal : .vertical) {
            layout {
                if platforms.isEmpty {
                    Button(action: onSettings) { Image(systemName: "plus").frame(width: 48, height: 48) }
                        .help("添加平台")
                }
                ForEach(platforms) { platform in
                    let data = model.menuBarData(for: platform)
                    Button { onSelect(platform) } label: {
                        VStack(spacing: settings.sideDockEnabled ? 8 : 3) {
                        Image(nsImage: MenuBarRenderer.image(platform: platform, data: data,
                            dark: settings.sideDockEnabled || (settings.appearanceMode.colorScheme ?? colorScheme) == .dark,
                            thickness: settings.menuBarRingThickness,
                            style: settings.menuBarProgressStyle, balanceAsRing: platform == .deepSeek, preserveLogoColors: true))
                            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: settings.sideDockEnabled ? 40 : 28, height: settings.sideDockEnabled ? 38 : 26)
                            .background(FloatingIconAnchor { onAnchor(platform, $0) }.allowsHitTesting(false))
                        if settings.sideDockEnabled {
                            Text(data.sideDockText).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                        }
                        }.frame(width: 48, height: settings.sideDockEnabled ? SideDockLayout.itemHeight : 48)
                    }.help(platform.title + " · " + data.description)
                        .accessibilityLabel(platform.title + " · " + data.description)
                        .onHover { onHover(platform, $0) }
                }
            }.padding(.horizontal, 7).padding(.vertical, settings.sideDockEnabled ? SideDockLayout.contentInset : 7)
        }.scrollIndicators(.never)
            .frame(width: surface.expandedSize.width, height: surface.expandedSize.height)
            .opacity(surface.collapsed ? 0 : 1)
            .allowsHitTesting(!surface.collapsed)
        Capsule().fill(settings.sideDockEnabled ? Color.white.opacity(0.65) : Color.primary.opacity(0.5))
            .frame(width: horizontal ? 32 : 3, height: horizontal ? 3 : 32)
            .opacity(surface.collapsed ? 1 : 0)
        }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .buttonStyle(.plain)
            .background {
                if settings.sideDockEnabled { Color.black }
                else { IslandBackground(effect: settings.backgroundEffect) }
            }
            .clipShape(SideDockShape(docked: settings.sideDockEnabled && !surface.collapsed,
                                     onLeft: settings.sideDockOnLeft,
                                     curveDepth: CGFloat(settings.sideDockCurveDepth)))
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.24), value: surface.collapsed)
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.24), value: horizontal)
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.24), value: surface.expandedSize)

            .highPriorityGesture(DragGesture(minimumDistance: 6)
                .onChanged { _ in onDrag(false) }.onEnded { _ in onDrag(true) })
            .contextMenu {
                Button("设置", action: onSettings)
                Divider()
                Button("退出应用") { NSApplication.shared.terminate(nil) }
            }
        }
            .preferredColorScheme(settings.appearanceMode.colorScheme)
    }
}
