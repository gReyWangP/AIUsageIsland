import AppKit
import Combine
import SwiftUI

enum IslandOpenURL {
    static func isOpenRequest(_ url: URL) -> Bool {
        url.scheme == "deepseekisland" && url.host == "open"
            && url.path.isEmpty && url.query == nil && url.fragment == nil
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: IslandModel
    private let presentation = IslandPresentation()
    private let settings: IslandSettings
    private var panel: IslandPanel?
    private var layout: NotchLayout?
    private var activeScreen: NSScreen?
    private var hoverTimer: Timer?
    private var hoverSuppressedUntilExit = false
    private var hoverState = IslandHoverState()
    private let fullscreenPolicy = FullscreenHoverPolicy()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var menuBarController: MenuBarStatusController?
    private var settingsWindow: NSWindow?
    private var settingsPreviewMode: IslandPresentation.Mode?
    private var utilities: DailyUtilities?
    private var recoveryController: SystemRecoveryController?
    private var guideController: IslandGuideController?
    private var windowTransition = IslandWindowTransition()
    private let browserAuthorizationWindows = BrowserAuthorizationWindowLevels()

    init(storageEvidence: InstallationStorageEvidence = .unavailable) {
        settings = IslandSettings(storageEvidence: storageEvidence)
        model = IslandModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.presentationSettings = settings
        // Settings uses a floating level. Hide it before presenting ordinary analysis windows.
        UsageAnalysisWindowController.shared.onShow = { [weak self] in self?.closeSettingsWindow() }
        settings.migrateAccountReminders(model)
        NSApplication.shared.setActivationPolicy(.accessory)
        let panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 565, height: 87),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = settings.appearanceMode.nsAppearance
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        let hostingView = NSHostingView(
            rootView: IslandAppearanceRoot(settings: settings,
                                          content: IslandView(model: model, presentation: presentation, settings: settings))
        )
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.panel = panel

        presentation.onModeChanged = { [weak self] in self?.applyPresentation() }
        presentation.onSurfaceSettled = { [weak self] revision in
            self?.settlePresentation(revision: revision)
        }
        presentation.onToggleSettings = { [weak self] in self?.toggleSettingsWindow() }
        // 尺寸是运行时实测的：排版换了、平台数变了、内容报错了都会变，
        // 面板必须跟着走，否则内容会被压得滚动或判定区对不上卡片。
        //
        // 注意：必须把闭包**收到的值**传下去，不能在里面回头读 presentation 属性。
        // `@Published` 是在 willSet 阶段发信号的，闭包执行时属性还是旧值——
        // 回头读就会每次都用上一次的尺寸，面板永远慢一拍
        //（表现为「内容已经换排版了，面板宽高还是旧的」）。
        presentation.$compactSize
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] size in
                MainActor.assumeIsolated {
                    self?.applyPresentation(compactSize: size)
                    if self?.settingsPreviewMode == .compact {
                        DispatchQueue.main.async { [weak self] in
                            if let window = self?.settingsWindow { self?.positionSettingsWindow(window) }
                        }
                    }
                }
            }
            .store(in: &cancellables)
        presentation.$detailSize
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] size in
                MainActor.assumeIsolated {
                    self?.applyPresentation(detailSize: size)
                    if self?.settingsPreviewMode == .expanded {
                        DispatchQueue.main.async { [weak self] in
                            if let window = self?.settingsWindow { self?.positionSettingsWindow(window) }
                        }
                    }
                }
            }
            .store(in: &cancellables)
        // 排版偏好变化**不需要**重算锚点：屏幕中心与顶边都没变，只有内容尺寸变了。
        // 尺寸会由 IslandView 的实测回调推上来，`$compactSize` / `$detailSize`
        // 的订阅会据此重设面板——所以这里什么都不用做，更不能收起面板。
        // （之前这里调用 updateScreen()，而它会 mode = .hidden + orderOut，
        //   导致「在设置里点任何一项，弹窗直接关掉」。）
        //
        // 换屏幕是另一回事：锚点真的变了，需要重新计算，但同样不必收起。
        ScreenTarget.observeSelection(of: settings) { [weak self] selection in
            self?.updateScreen(selection: selection, hide: false)
        }
            .store(in: &cancellables)

        // 改哪一项就预览哪一项。
        //
        // 「悬浮内容排版」的效果只在悬浮条上可见，「详情排版」只在展开态可见——
        // 之前改悬浮排版时顶部还停在详情，用户根本看不到改动，只能盲调。
        // 这里把对应形态顶上来，让改动立刻可见。
        // dropFirst：@Published 订阅时会先发一次当前值，不能让它把形态顶掉。
        settings.$compactLayout
            .dropFirst()
            .sink { [weak self] layout in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 先按新排版把宽度写死，再切形态——顺序不能反，
                    // 否则 applyPresentation 会先用旧尺寸摆一次面板。
                    // 宽度完全由排版决定，不该等测量：SwiftUI 有时不重新派发
                    // 偏好值，尺寸会永远停在旧排版，横向条 565 宽却只露出
                    // 中间 200 pt（恰好是 Spacer 空白），看着就是「一块黑的」。
                    let width = layout.barWidth(hasNotch: self.presentation.hasNotch,
                                                notchWidth: self.presentation.notchWidth,
                                                horizontalBarWidth: self.presentation.horizontalBarWidth)
                    self.presentation.compactSize = CGSize(width: width,
                                                           height: self.presentation.compactHeights[layout.rawValue]
                                                            ?? self.presentation.compactSize.height)
                    // 设置已提交后再预览；窗口包络保留正在退出的布局。
                    DispatchQueue.main.async { self.previewSurface(.compact) }
                }
            }
            .store(in: &cancellables)
        settings.$detailLayout
            .dropFirst()
            .sink { [weak self] layout in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 同悬浮条：先按新排版把尺寸写死再切形态，不能等测量。
                    self.presentation.detailSize = self.presentation.detailSize(
                        for: layout, platformCount: self.model.detailSnapshots.count)
                    // 下一轮更新时预览已提交的新排版。
                    DispatchQueue.main.async { self.previewSurface(.expanded) }
                }
            }
            .store(in: &cancellables)

        settings.$appearanceMode
            .sink { [weak self] mode in
                MainActor.assumeIsolated {
                    self?.panel?.appearance = mode.nsAppearance
                    self?.settingsWindow?.appearance = mode.nsAppearance
                }
            }
            .store(in: &cancellables)

        model.onAccountsChanged = { [weak self] in
            self?.applyPresentation()
        }
        model.onZhipuConnected = { [weak self] in self?.accountLoginCompleted() }
        model.onPlatformSelected = { [weak self] in self?.showDetails() }

        model.objectWillChange
            .receive(on: RunLoop.main)
            .map { [weak model] in (model?.isSigningIn ?? false) || (model?.chatGPTSigningIn ?? false) }
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self else { return }
                let wasActive = self.browserAuthorizationWindows.isActive
                self.browserAuthorizationWindows.update(active: active,
                    windows: [self.settingsWindow, self.panel].compactMap { $0 })
                if wasActive && !active { self.accountLoginCompleted() }
            }.store(in: &cancellables)

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handleCameraClick(at: NSEvent.mouseLocation) ?? false
            }
            return handled ? nil : event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { _ = self?.handleCameraClick(at: point) }
            }
        }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        menuBarController = MenuBarStatusController(model: model, settings: settings) { [weak self] in
            self?.showDetails()
        }
        utilities = DailyUtilities(model: model, settings: settings,
            onOpen: { [weak self] in self?.showDetails() },
            perform: { [weak self] action in self?.performShortcut(action) })
        recoveryController = SystemRecoveryController(model: model, onSleep: { [weak self] in
            guard let self else { return }
            self.hoverState.reset()
            self.windowTransition.invalidate()
            self.presentation.mode = .hidden
            self.panel?.orderOut(nil)
        }, onWake: { [weak self] in
            self?.updateScreen()
            self?.utilities?.login.refreshStatus()
        })
        utilities?.alerts.onOpenMetric = { [weak self] metric in
            self?.model.focusNotification(metric)
            self?.showDetails()
        }
        utilities?.alerts.onOpenAccountMetric = { [weak self] account, metric in
            self?.model.focusNotification(metric, account: account)
            self?.showDetails()
        }
        model.startPolling()
        updateScreen()

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.utilities?.login.refreshStatus()
                if let alerts = self?.utilities?.alerts { Task { await alerts.updatePermission() } }
            }
        }
        guideController = IslandGuideController(settings: settings) { [weak self] in self?.showDetails() }
        if settings.shouldShowStartupGuide {
            guideController?.show()
        } else if model.platformAccounts.enabled.isEmpty {
            showDetails()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScreen() }
        }
    }

    private var terminationPending = false
    private let historyShutdown = HistoryShutdown()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        model.pauseAccountPolling()
        let runtimes = Array(model.accountRuntimes.values)
        runtimes.forEach { $0.stopAcceptingHistoryUpdates() }
        historyShutdown.begin(flush: {
            for runtime in runtimes { await runtime.finishHistoryLoading() }
            await HistoryPersistence.flushAll()
        }) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        utilities?.shortcuts.shutdown()
        recoveryController?.stop()
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: IslandOpenURL.isOpenRequest) else { return }
        showDetails()
    }

    /// 把岛切到指定形态，用于预览正在调整的那项设置。
    private func previewSurface(_ mode: IslandPresentation.Mode) {
        guard presentation.showingSettings, let panel else { return }
        // 展开／收起要改面板尺寸，交给 applyPresentation 统一处理。
        presentation.pinned = false
        presentation.mode = mode
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        applyPresentation(animated: true)
        settingsPreviewMode = mode
        if let settingsWindow { positionSettingsWindow(settingsWindow) }
    }

    // MARK: - 设置窗口

    /// 设置页是独立窗口，不占用详情面板。
    ///
    /// 详情面板的宽度按平台数计算（1 个平台 360 pt、3 个平台 722 pt），
    /// 设置页塞进去会随平台数变窄变高，还得滚动才能填完。做成独立窗口后
    /// 尺寸只由设置内容决定，岛那边也能实时反映改动。
    private func toggleSettingsWindow() {
        if let window = settingsWindow, window.isVisible {
            window.orderOut(nil)
            presentation.showingSettings = false
            settingsPreviewMode = nil
            return
        }
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        positionSettingsWindow(window)
        window.makeKeyAndOrderFront(nil)
        // accessory 应用调用 activate 未必能压过其它应用的前窗，
        // orderFrontRegardless 才能确保它出现在最上层。
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        presentation.showingSettings = true
        positionSettingsWindow(window)
    }

    private func closeSettingsWindow() {
        settingsWindow?.orderOut(nil)
        presentation.showingSettings = false
        settingsPreviewMode = nil
    }

    func makeSettingsWindow() -> NSWindow {
        let root = IslandSettingsView(settings: settings, model: model, utilities: utilities, onShowGuide: { [weak self] in
            self?.closeSettingsWindow()
            self?.guideController?.show()
        }, onPreview: { [weak self] mode in self?.previewSurface(mode) })
            .padding(18)
            .frame(width: Self.settingsWindowWidth)
            .frame(minHeight: 0, idealHeight: Self.settingsWindowHeight, maxHeight: Self.settingsWindowHeight)
            .background(IslandSettingsBackground(settings: settings))
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: IslandAppearanceRoot(settings: settings, content: root)))
        // 显式定死内容尺寸。SwiftUI 的布局要等一轮 runloop 才完成，
        // 建窗时读到的 frame 是不可靠的——按它算居中就会偏。
        // 数值来自 DetailLayoutTests 的实测，包含两页设置入口。
        window.setContentSize(NSSize(width: Self.settingsWindowWidth,
                                     height: Self.settingsWindowHeight))
        window.title = "AIUsageIsland · 设置"
        window.styleMask = [.titled, .closable]
        // 岛在 statusBar 层级，内屏上居中的设置窗口可能与详情重叠。
        // 设置要高一层，才不会被打开或实时预览时的 orderFrontRegardless 盖住。
        // canJoinAllSpaces + fullScreenAuxiliary 保证全屏时也能看到。
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 内容区可由 NSVisualEffectView 模糊；原生标题栏仍需自己的不透明底色。
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.isOpaque = false
        window.appearance = settings.appearanceMode.nsAppearance
        browserAuthorizationWindows.update(active: browserAuthorizationWindows.isActive, windows: [window])
        return window
    }

    private static let settingsWindowWidth: CGFloat = 680
    /// 默认内容高度；屏幕顶部预览时按剩余空间收缩，列表可滚动。
    private static let settingsWindowHeight: CGFloat = 680

    /// 设置窗口跟随岛的目标屏幕，不能沿用窗口上次所在的屏幕。
    private func positionSettingsWindow(_ window: NSWindow, on targetScreen: NSScreen? = nil) {
        guard let screen = targetScreen
                ?? activeScreen
                ?? ScreenTarget.screen(for: settings.screenSelection, in: NSScreen.screens) else { return }
        // 显式按 visibleFrame 算，不用 window.center()：实测后者在这个场景下
        // 把窗口放高了 265 pt（midY 985 而屏幕中心是 720）。
        let visible = screen.visibleFrame
        let titlebar = window.frame.height - window.contentLayoutRect.height
        let previewHeight: CGFloat?
        switch settingsPreviewMode {
        case .expanded: previewHeight = presentation.detailSize.height
        case .compact: previewHeight = presentation.compactSize.height
        default: previewHeight = nil
        }
        window.setFrame(Self.settingsWindowFrame(visible: visible, screenTop: screen.frame.maxY,
            previewHeight: previewHeight, titlebarHeight: titlebar), display: true)
    }

    static func settingsWindowFrame(visible: NSRect, screenTop: CGFloat,
                                    previewHeight: CGFloat?, titlebarHeight: CGFloat) -> NSRect {
        let top = previewHeight.map { min(visible.maxY, screenTop - $0 - 16) } ?? visible.maxY
        let contentHeight = min(settingsWindowHeight, max(0, top - visible.minY - titlebarHeight - 16))
        let height = contentHeight + titlebarHeight
        let y = previewHeight == nil ? visible.midY - height / 2 : top - height
        return NSRect(x: visible.midX - settingsWindowWidth / 2, y: max(visible.minY, y),
                      width: settingsWindowWidth, height: height)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        presentation.showingSettings = false
        settingsPreviewMode = nil
    }

    // MARK: - 面板

    /// 按当前模式与实测尺寸重设面板 frame。尺寸没变就不动，避免无谓重排。
    /// 重设面板位置与大小。
    ///
    /// `compactSize` / `detailSize` 用于传入**订阅回调刚收到的值**：
    /// `@Published` 在 willSet 阶段发信号，此时 `presentation` 上的属性还是旧值，
    /// 回头读会慢一拍。其余调用方（展开／收起等）传 nil，读当前值即可。
    private func applyPresentation(animated: Bool = true,
                                   compactSize: CGSize? = nil,
                                   detailSize: CGSize? = nil) {
        guard let panel, let layout else { return }
        let wanted: NSRect
        switch presentation.mode {
        case .hidden, .compact:
            wanted = layout.compactFrame(size: compactSize ?? presentation.compactSize)
        case .expanded:
            wanted = layout.detailFrame(size: detailSize ?? presentation.detailSize)
        }
        let target = sanitized(wanted, layout: layout)
        let mode = presentation.mode
        let surface = mode == .hidden
            ? CGSize(width: presentation.hasNotch ? presentation.notchWidth : 0,
                     height: presentation.hasNotch ? presentation.bandHeight : 0)
            : target.size
        let previous = presentation.surfaceTransition
        // 重复尺寸通知不能提前结束正在播放的动画。
        if animated && previous.size == surface && previous.mode == mode,
           windowTransition.target == target || panel.frame == target { return }
        let shouldAnimate = animated && panel.isVisible
        let envelope = windowTransition.begin(from: panel.frame, to: target,
                                              animated: shouldAnimate)
        panel.setFrame(envelope, display: true)
        presentation.surfaceTransition = IslandSurfaceTransition(
            revision: windowTransition.revision, size: surface,
            mode: mode, animated: shouldAnimate)
    }

    private func settlePresentation(revision: Int) {
        guard let panel, let target = windowTransition.complete(revision: revision) else { return }
        panel.setFrame(target, display: true)
        guard presentation.mode == .hidden else { return }
        if hoverSuppressedUntilExit || model.isSleeping
            || (settings.pausesHoverInFullscreen && fullscreenPolicy.isFullscreen(on: activeScreen)) {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }
        // 收起途中重新移入时立即反向展开；旧完成回调不能关闭新窗口。
        if let layout, hoverState.shouldShow(in: layout, pointer: NSEvent.mouseLocation,
                                         mode: .hidden,
                                         pinned: presentation.pinned,
                                         compactSize: presentation.compactSize,
                                         detailSize: presentation.detailSize,
                                         excluding: menuBarController?.screenFrame,
                                         screenFrames: NSScreen.screens.map(\.frame)),
           !presentation.showingSettings {
            revealCompactBar(in: panel)
        } else {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        }
    }

    /// 面板 frame 的最后一道防线。
    ///
    /// 只要尺寸非法（NaN / 无穷 / 超过屏幕），就退回到最小的悬浮条，
    /// 而不是把这个 frame 交给 `setFrame`——那会变成一个盖住整块屏幕的黑窗口。
    private func sanitized(_ rect: NSRect, layout: NotchLayout) -> NSRect {
        let screenWidth = presentation.screenWidth
        let screenHeight = presentation.screenHeight
        let sane = rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 1 && rect.height > 1
            && screenWidth > 1 && screenHeight > 1
            && rect.width <= screenWidth && rect.height <= screenHeight
        guard sane else {
            NSLog("⚠️ 面板 frame 非法，退回最小悬浮条：%@", "\(rect)")
            return layout.compactFrame(size: CGSize(width: 200, height: 40))
        }
        return rect
    }

    private func showDetails() {
        hoverSuppressedUntilExit = false
        guard let panel else { return }
        hoverState.reset()
        panel.ignoresMouseEvents = false
        closeSettingsWindow()
        panel.orderFrontRegardless()
        presentation.openDetails()
        applyPresentation()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func accountLoginCompleted() {
        guard !browserAuthorizationWindows.isActive else { return }
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            showDetails()
        }
    }

    private func handleCameraClick(at point: NSPoint) -> Bool {
        updateAutomaticScreen(at: point)
        guard let layout, let panel, layout.acceptsCameraClick(point) else { return false }
        hoverState.reset()
        if !presentation.visible {
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            presentation.mode = .expanded
        } else {
            presentation.expanded.toggle()
        }
        return true
    }

    /// 重新计算锚点与屏幕几何。
    ///
    /// - Parameter hide: 屏幕增删或分辨率变化时传 true——原来的位置已无意义，
    ///   收起面板；只是切换目标屏幕时传 false，面板原地挪过去即可。
    private func updateScreen(selection: ScreenSelection? = nil, hide: Bool = true,
                              targetScreen: NSScreen? = nil) {
        guard let panel else { return }
        hoverSuppressedUntilExit = false
        hoverState.reset()
        let retainedID = selection == nil ? activeScreen.map { ScreenTarget.displayID(of: $0) } : nil
        guard let screen = targetScreen ?? ScreenTarget.screen(for: selection ?? settings.screenSelection,
            in: NSScreen.screens, retaining: retainedID) else {
            layout = nil
            activeScreen = nil
            windowTransition.invalidate()
            presentation.mode = .hidden
            panel.orderOut(nil)
            return
        }
        windowTransition.invalidate()
        activeScreen = screen
        let layout = NotchLayout(screen: screen)
        self.layout = layout
        presentation.applyScreenLayout(layout, screenSize: screen.frame.size,
            compactLayout: settings.compactLayout, detailLayout: settings.detailLayout,
            platformCount: model.detailSnapshots.count)
        presentation.updateVisibilityForScreenChange(hide: hide, sleeping: model.isSleeping)
        if presentation.mode == .hidden {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        }
        applyPresentation(animated: false)
        if presentation.visible { panel.orderFrontRegardless() }
        guideController?.reposition()
        if let settingsWindow, settingsWindow.isVisible {
            positionSettingsWindow(settingsWindow, on: screen)
        }
    }

    /// 复用同一个面板，进入另一屏顶部时原子更新锚点和尺寸。
    private func updateAutomaticScreen(at point: NSPoint) {
        guard settings.screenSelection == .automatic, !presentation.pinned else { return }
        let interactionActive = browserAuthorizationWindows.isActive || model.isSleeping
            || presentation.showingSettings || guideController?.isVisible == true
            || model.officialResetCard.isPopoverPresented
        guard !interactionActive else { return }
        let screens = NSScreen.screens
        guard let index = ScreenTarget.hoverIndex(for: settings.screenSelection,
            layouts: screens.map { NotchLayout(screen: $0) }, pointer: point,
            pinned: presentation.pinned, interactionActive: interactionActive,
            excluding: menuBarController?.screenFrame) else { return }
        let screen = screens[index]
        guard activeScreen.map({ ScreenTarget.displayID(of: $0) }) != ScreenTarget.displayID(of: screen)
            || layout?.screenFrame != screen.frame else { return }
        if settings.pausesHoverInFullscreen && fullscreenPolicy.isFullscreen(on: screen) { return }
        updateScreen(hide: false, targetScreen: screen)
    }

    private func checkPointer() {
        updateAutomaticScreen(at: NSEvent.mouseLocation)
        guard let layout, let panel else { return }
        if browserAuthorizationWindows.isActive { return }
        if model.isSleeping { return }
        if settings.pausesHoverInFullscreen,
           fullscreenPolicy.isFullscreen(on: activeScreen),
           !presentation.showingSettings, presentation.mode != .expanded {
            hoverState.reset()
            if presentation.mode == .compact { presentation.mode = .hidden }
            panel.orderOut(nil)
            return
        }
        if hoverSuppressedUntilExit {
            let inside = layout.shouldShow(pointer: NSEvent.mouseLocation, visible: false,
                expanded: false, pinned: false, compactSize: presentation.compactSize,
                detailSize: presentation.detailSize, screenFrames: NSScreen.screens.map(\.frame))
            if inside { return }
            hoverSuppressedUntilExit = false
        }
        if guideController?.isVisible == true {
            hoverState.reset()
            return
        }
        // 设置窗口开着时，岛**保持可见但不强制展开**。
        //
        // 设置里两项对应两个不同的界面：「悬浮内容排版」要收起成悬浮条才看得到，
        // 「详情排版」要展开才看得到。强制展开会把前者的实时预览堵死，
        // 用户就只能在展开态里瞎调。所以这里只保证不消失，
        // 展开／收起交给用户（点 ⌃ 收起即可看着悬浮条改）。
        if presentation.showingSettings {
            hoverState.reset()
            if !presentation.visible {
                panel.ignoresMouseEvents = false
                panel.orderFrontRegardless()
                presentation.mode = .compact
            }
            return
        }
        if model.platformAccounts.enabled.isEmpty && presentation.expanded { return }
        let show = hoverState.shouldShow(
            in: layout, pointer: NSEvent.mouseLocation,
            mode: presentation.mode,
            pinned: presentation.pinned,
            compactSize: presentation.compactSize,
            detailSize: presentation.detailSize,
            excluding: menuBarController?.screenFrame,
            screenFrames: NSScreen.screens.map(\.frame)
        )
        if presentation.shouldWaitBeforeHiding(at: .now, pointerInside: show) { return }
        if show {
            hoverState.reset()
            if !presentation.visible { revealCompactBar(in: panel) }
        } else if presentation.visible && hoverState.shouldHide(pointerInside: false, at: .now, holdingPopover: model.officialResetCard.isPopoverPresented) {
            beginCompactHide(in: panel)
        }
    }

    private func performShortcut(_ action: ShortcutAction) {
        switch action {
        case .toggle:
            if presentation.expanded {
                presentation.expanded = false
                presentation.pinned = false
                hoverState.reset()
            } else { showDetails() }
        case .hide: hideFromShortcut()
        case .refresh: Task { await model.refresh() }
        }
    }
    private func hideFromShortcut() {
        closeSettingsWindow()
        presentation.pinned = false
        hoverState.reset()
        // 若鼠标仍在原触发区，等它离开一次后才恢复自动唤出。
        hoverSuppressedUntilExit = true
        presentation.mode = .hidden
    }

    private func revealCompactBar(in panel: IslandPanel) {
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        presentation.visible = true
        applyPresentation()
    }

    private func beginCompactHide(in panel: IslandPanel) {
        presentation.mode = .hidden
    }

}

let app = NSApplication.shared
// Check before constructing the model: older app copies do not know about the file lock.
let currentProcess = NSRunningApplication.current
let existingInstance = NSRunningApplication.runningApplications(withBundleIdentifier: "com.deepseekisland.app")
    .filter { other in
        guard other.processIdentifier != currentProcess.processIdentifier, !other.isTerminated else { return false }
        if let otherDate = other.launchDate, let currentDate = currentProcess.launchDate, otherDate != currentDate {
            return otherDate < currentDate
        }
        return other.processIdentifier < currentProcess.processIdentifier
    }.first
if let existingInstance {
    _ = existingInstance.activate(options: [.activateAllWindows])
    exit(0)
}
let storageEvidence = InstallationStorageEvidence.capture(directory: SessionStore.shared.directory)
let instanceLock: ApplicationInstanceLock
do {
    instanceLock = try ApplicationInstanceLock(directory: SessionStore.shared.directory)
} catch {
    let alert = NSAlert()
    alert.messageText = "AIUsageIsland 无法启动"
    alert.informativeText = (error as? ApplicationInstanceLock.Failure) == .alreadyRunning
        ? "已有应用副本正在使用账号数据，请使用正在运行的版本。"
        : "无法取得账号数据目录的独占访问权，请检查目录权限后重试。"
    alert.addButton(withTitle: "退出")
    alert.runModal()
    exit(1)
}
let delegate = AppDelegate(storageEvidence: storageEvidence)
app.delegate = delegate
withExtendedLifetime(instanceLock) { app.run() }
