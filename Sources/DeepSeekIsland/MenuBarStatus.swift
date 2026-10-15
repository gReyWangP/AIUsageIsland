import AppKit
import Combine
import Foundation

enum MenuBarProgressStyle: String, CaseIterable, Identifiable {
    case ring, waterLevel
    var id: String { rawValue }
    var title: String { self == .ring ? "圆环" : "水位" }
}

enum MenuBarRingThickness: String, CaseIterable, Identifiable {
    case thin, standard, thick
    var id: String { rawValue }
    var title: String {
        switch self { case .thin: "细"; case .standard: "标准"; case .thick: "粗" }
    }
    var lineWidth: CGFloat {
        switch self { case .thin: 1.8; case .standard: 2.4; case .thick: 3.0 }
    }
}

// Compatibility names for existing presentation code and saved callers.
typealias MenuBarMetric = UsageMetric
typealias MenuBarData = UsageReading

enum MenuBarHealth: Equatable {
    case healthy, warning, critical, unknown
    var color: NSColor {
        switch self {
        case .healthy: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        case .unknown: .secondaryLabelColor
        }
    }
}

extension UsageReading {
    var health: MenuBarHealth {
        switch self {
        case .balance(let amount, _):
            amount >= 5 ? .healthy : amount >= 1 ? .warning : .critical
        case .quota(let remaining, _):
            remaining >= 20 ? .healthy : remaining >= 10 ? .warning : .critical
        case .unlimited: .healthy
        case .unavailable: .unknown
        }
    }

    var balanceText: String? {
        guard case .balance(let amount, let currency) = self else { return nil }
        let prefix = currency == "CNY" ? "¥" : currency == "USD" ? "$" : currency + " "
        if amount > 0 && amount < Decimal(string: "0.01")! { return "<\(prefix)0.01" }
        let digits = amount >= 1 ? 0 : 2
        var raw = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, digits, .down)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return prefix + (formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "—")
    }

}

extension IslandModel {
    /// An unfinished login must not displace another authorized account in the status item.
    func menuBarSource(for platform: UsagePlatform, account: AccountReference? = nil) -> AccountRuntime {
        if let account, account.platform == platform, savedAccounts.contains(account) {
            return accountRuntime(for: account)
        }
        guard !(hasConnectedAccount(for: platform) && hasLoadedAccountData(for: platform)), platformAccounts.enabled.contains(platform) else { return selectedRuntime(for: platform) }
        for account in orderedSavedAccounts where account.platform == platform && account.profileID != accountProfiles.active(for: platform).id {
            let worker = accountRuntime(for: account)
            if worker.hasConnectedAccount(for: platform) && worker.hasLoadedAccountData(for: platform) { return worker }
        }
        return selectedRuntime(for: platform)
    }
    func menuBarAccount(for platform: UsagePlatform) -> AccountReference {
        let source = menuBarSource(for: platform)
        return source.account
    }
    func menuBarTitle(for metric: MenuBarMetric) -> String {
        let name = accountLabel(menuBarAccount(for: metric.platform))
        return name + " · " + (metric == .deepSeekBalance ? "剩余余额" : metric.windowLabel + "剩余额度")
    }
    func menuBarFreshness(for platform: UsagePlatform) -> DataFreshness {
        menuBarSource(for: platform).freshness(for: platform)
    }
    func menuBarData(for platform: UsagePlatform) -> MenuBarData {
        menuBarData(for: MenuBarMetric.defaultMetric(for: platform))
    }

    func menuBarData(for metric: MenuBarMetric) -> MenuBarData {
        menuBarSource(for: metric.platform).localMenuBarData(for: metric)
    }

}

extension AccountRuntime {
    func localMenuBarData(for metric: MenuBarMetric) -> MenuBarData {
        usageReading(for: metric)
    }
}

@MainActor
enum MenuBarRenderer {
    static func image(platform: UsagePlatform, data: MenuBarData, dark: Bool, thickness: MenuBarRingThickness = .standard, style: MenuBarProgressStyle = .ring, balanceAsRing: Bool = false) -> NSImage {
        let text = platform == .deepSeek && !balanceAsRing ? (data.balanceText ?? "—") : nil
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let width = text.map { max(42, ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 25) } ?? 20
        let size = NSSize(width: width, height: 18)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let image = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let health = data.health.color
                if let text {
                    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                    health.setStroke()
                    border.lineWidth = 0.8
                    border.stroke()
                    drawLogo(platform, in: NSRect(x: 4, y: 3, width: 16, height: 12),
                             color: data.health == .unknown ? .secondaryLabelColor : .labelColor)
                    draw(text, in: NSRect(x: 23, y: 0, width: rect.width - 27, height: rect.height),
                         font: font, color: health)
                } else if case .unlimited = data {
                    draw("∞", in: rect, font: NSFont.systemFont(ofSize: 17, weight: .medium), color: health)
                } else if style == .waterLevel && !balanceAsRing {
                    let container = NSRect(x: 1.4, y: 0.4, width: 17.2, height: 17.2)
                    let boundary = NSBezierPath(ovalIn: container)
                    NSColor.labelColor.withAlphaComponent(0.06).setFill()
                    boundary.fill()
                    if case .quota(let remaining, _) = data, remaining.isFinite {
                        NSGraphicsContext.saveGraphicsState()
                        boundary.addClip()
                        // 实色水位不受壁纸混色影响；深色菜单栏使用较暗填充，衬托白色 Logo。
                        let fill = health.usingColorSpace(.deviceRGB) ?? health
                        let dimming: CGFloat = dark ? 0.58 : 1
                        NSColor(deviceRed: fill.redComponent * dimming,
                                green: fill.greenComponent * dimming,
                                blue: fill.blueComponent * dimming, alpha: 1).setFill()
                        // AppKit 坐标向上，固定水平面从容器底部升高；不播放波浪动画。
                        NSRect(x: container.minX, y: container.minY, width: container.width,
                               height: container.height * max(0, min(100, remaining)) / 100).fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    health.withAlphaComponent(0.7).setStroke()
                    boundary.lineWidth = 0.7
                    boundary.stroke()
                    if data.health == .unknown {
                        draw("?", in: container, font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
                    } else {
                        drawLogo(platform, in: NSRect(x: 3.75, y: 2.75, width: 12.5, height: 12.5),
                                 color: .labelColor, emphasized: true)
                    }
                } else {
                    // 外缘固定在 18 pt 高度内，线条向内增厚，保留中心 Logo。
                    let radius = 8.9 - thickness.lineWidth / 2
                    let track = NSBezierPath(ovalIn: NSRect(x: 10 - radius, y: 9 - radius, width: radius * 2, height: radius * 2))
                    NSColor.secondaryLabelColor.withAlphaComponent(0.22).setStroke()
                    track.lineWidth = thickness.lineWidth
                    track.stroke()
                    if balanceAsRing, case .balance = data {
                        health.setStroke()
                        track.stroke()
                    } else if case .quota(let remaining, _) = data, remaining > 0 {
                        let arc = NSBezierPath()
                        arc.appendArc(withCenter: NSPoint(x: 10, y: 9), radius: radius,
                                      startAngle: 90, endAngle: 90 - 360 * min(100, remaining) / 100, clockwise: true)
                        arc.lineWidth = thickness.lineWidth
                        arc.lineCapStyle = .round
                        health.setStroke()
                        arc.stroke()
                    } else if data.health == .critical {
                        NSColor.systemRed.withAlphaComponent(0.25).setStroke()
                        track.stroke()
                    }
                    if data.health == .unknown {
                        draw("?", in: NSRect(x: 1, y: 0, width: 18, height: 18),
                             font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor)
                    } else {
                        drawLogo(platform, in: NSRect(x: 4.25, y: 3.25, width: 11.5, height: 11.5), color: .labelColor)
                    }
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 官方图形资源在构建时打包，离线使用；不再用平台首字母。
    private static let logos: [UsagePlatform: NSImage] = {
        var result: [UsagePlatform: NSImage] = [:]
        for (platform, name, ext) in [(UsagePlatform.deepSeek, "DeepSeekLogo", "svg"),
                                      (.chatGPT, "ChatGPTLogo", "png"),
                                      (.zhipu, "CodingPlanLogo", "png")] {
            if let url = IslandResources.bundle?.url(forResource: name, withExtension: ext),
               let image = NSImage(contentsOf: url) { result[platform] = image }
        }
        return result
    }()

    private static func drawLogo(_ platform: UsagePlatform, in rect: NSRect, color: NSColor, emphasized: Bool = false) {
        guard let logo = logos[platform] else { return }
        let tinted = NSImage(size: logo.size, flipped: false) { bounds in
            logo.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            color.setFill()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let scale = min(rect.width / logo.size.width, rect.height / logo.size.height)
        let size = NSSize(width: logo.size.width * scale, height: logo.size.height * scale)
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        // 小尺寸下细线的抗锯齿像素容易被实色填充混淡；原位复绘增强线条，不扩大 Logo。
        if emphasized { tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1) }
    }

    private static func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                withAttributes: attributes)
    }
}

private struct MenuBarImageState: Equatable {
    let metric: UsageMetric
    let data: UsageReading
    let autoFocus: Bool
    let thickness: MenuBarRingThickness
    let style: MenuBarProgressStyle
}

extension MenuBarRenderer {
    /// AppKit temporarily changes the source view appearance while drawing menu-bar
    /// replicas. Resolve colors during drawing instead of observing those changes.
    static func adaptiveImage(metric: UsageMetric, data: UsageReading, autoFocus: Bool,
                              thickness: MenuBarRingThickness, style: MenuBarProgressStyle) -> NSImage {
        func variant(dark: Bool) -> NSImage {
            autoFocus
                ? autoImage(platform: metric.platform, data: data, dark: dark,
                    thickness: thickness, style: style, windowLabel: metric.windowLabel)
                : image(platform: metric.platform, data: data, dark: dark, thickness: thickness, style: style)
        }
        let light = variant(dark: false)
        let dark = variant(dark: true)
        let result = NSImage(size: light.size, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            (isDark ? dark : light).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        result.isTemplate = false
        result.cacheMode = .never
        return result
    }
}

/// 只订阅现有模型；不启动计时器，不发起网络请求。
@MainActor
final class MenuBarStatusController: NSObject {
    let model: IslandModel
    let settings: IslandSettings
    let onOpen: () -> Void
    private var autoFocus = MenuBarAutoFocus()
    var autoDisplayedMetric: MenuBarMetric?
    var onRefresh: ((UsagePlatform) -> Void)?
    var onShowSettings: () -> Void = {}
    var onPresentPopover: () -> Void = {}
    private var popover: MenuBarPopoverController?
    private var popoverState = MenuBarHoverState()
    private var quickMenuActive = false
    var isPopoverVisible: Bool { popover?.isVisible == true }
    private var item: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var lastImageState: MenuBarImageState?
    var statusButton: NSStatusBarButton? { item?.button }

    init(model: IslandModel, settings: IslandSettings, onOpen: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.onOpen = onOpen
        super.init()
        model.objectWillChange.merge(with: settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
        update()
    }

    func source(for platform: UsagePlatform) -> AccountRuntime {
        model.menuBarSource(for: platform, account: settings.menuBarAccount)
    }
    func data(for metric: MenuBarMetric) -> MenuBarData {
        source(for: metric.platform).localMenuBarData(for: metric)
    }
    func freshness(for platform: UsagePlatform) -> DataFreshness {
        source(for: platform).freshness(for: platform)
    }
    func title(for metric: MenuBarMetric) -> String {
        let source = self.source(for: metric.platform)
        let account = source.account
        return model.accountLabel(account) + " · "
            + (metric == .deepSeekBalance ? "剩余余额" : metric.windowLabel + "剩余额度")
    }
    func displayedAccount(for platform: UsagePlatform) -> AccountReference {
        source(for: platform).account
    }

    func update() {
        // Upgrade the legacy platform-only preference once. Invalidated account
        // references are repaired explicitly, rather than borrowing a different identity silently.
        if !model.savedAccounts.contains(where: { $0 == settings.menuBarAccount }) {
            if model.platformAccounts.enabled.contains(settings.menuBarMetric.platform) {
                let platform = settings.menuBarMetric.platform
                let preferred = model.menuBarAccount(for: platform)
                settings.menuBarAccount = model.accountRuntime(for: preferred).hasConnectedAccount(for: platform)
                    ? preferred : model.orderedSavedAccounts.first {
                        $0.platform == platform && model.accountRuntime(for: $0).hasConnectedAccount(for: platform)
                    } ?? preferred
            } else if let first = model.orderedSavedAccounts.first { settings.menuBarAccount = first }
            else if settings.menuBarAccount != nil { settings.menuBarAccount = nil }
        }
        if settings.menuBarAutoFocusEnabled {
            let candidates = settings.orderedPlatforms.filter { model.platformAccounts.enabled.contains($0) && (settings.menuBarAccount == nil || settings.menuBarAccount?.platform == $0) }
                .flatMap { platform in MenuBarMetric.allCases.filter { $0.platform == platform } }
                .filter { freshness(for: $0.platform).allowsAlerts }
                .map { MenuBarFocusCandidate(metric: $0, data: self.data(for: $0)) }
            let fallback = settings.menuBarAccount.map { account in
                settings.menuBarMetric.platform == account.platform ? settings.menuBarMetric : .defaultMetric(for: account.platform)
            } ?? settings.menuBarMetric
            // 更新中只是暂态：保留焦点、显示未知／更新中，且允许其他指标严重升级时抢占。
            let loadingCurrent = autoDisplayedMetric.flatMap { metric -> MenuBarMetric? in
                supportsMetric(metric) && freshness(for: metric.platform).phase == .loading ? metric : nil
            }
            autoDisplayedMetric = autoFocus.resolve(candidates, fallback: fallback, temporarilyLoading: loadingCurrent)
        } else {
            autoDisplayedMetric = nil
            autoFocus = MenuBarAutoFocus()
        }
        guard settings.showsMenuBarItem else {
            dismissPopover()
            lastImageState = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.target = self
            item?.button?.action = #selector(openDetails)
            item?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        }
        guard let button = statusButton else { return }
        let metric = displayedMetric
        let platform = metric.platform
        let data: MenuBarData = settings.menuBarAutoFocusEnabled && !freshness(for: platform).allowsAlerts
            ? .unavailable(freshness(for: platform).label) : self.data(for: metric)
        let imageState = MenuBarImageState(metric: metric, data: data,
            autoFocus: settings.menuBarAutoFocusEnabled, thickness: settings.menuBarRingThickness,
            style: settings.menuBarProgressStyle)
        if lastImageState != imageState {
            button.image = MenuBarRenderer.adaptiveImage(metric: metric, data: data,
                autoFocus: imageState.autoFocus, thickness: imageState.thickness, style: imageState.style)
            lastImageState = imageState
        }
        let description = title(for: metric) + "，" + data.description
        button.toolTip = settings.menuBarHoverEnabled ? nil : description
        if isPopoverVisible { popover?.update(makePopoverView(), appearance: settings.appearanceMode.nsAppearance) }
        button.setAccessibilityLabel(description)
    }

    /// NSStatusBar 按钮的屏幕坐标；排除鼠标触发与浮窗保留区域。
    var screenFrame: NSRect? {
        guard let button = statusButton, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func checkPointer(at point: NSPoint, now: Date = .now, suspended: Bool = false, hoverSuspended: Bool = false) {
        let available = settings.showsMenuBarItem && statusButton?.window?.isVisible == true
            && !suspended && !model.isSleeping && !quickMenuActive
        popover?.reposition()
        let previous = popoverState.mode
        popoverState.update(iconInside: screenFrame?.contains(point) == true,
                            cardInside: popover?.screenFrame?.contains(point) == true,
                            enabled: settings.menuBarHoverEnabled && !hoverSuspended, available: available, at: now)
        if popoverState.mode == .hidden {
            if isPopoverVisible { popover?.close() }
        } else if previous == .hidden { showPopover() }
    }

    func togglePopover() {
        guard settings.showsMenuBarItem, !model.isSleeping else { return }
        popoverState.togglePinned()
        if popoverState.mode == .hidden { popover?.close() }
        else {
            showPopover()
            if isPopoverVisible { popover?.focus() }
        }
    }

    func openPinnedPopover() {
        guard settings.showsMenuBarItem, !model.isSleeping else { return }
        if popoverState.mode != .pinned { popoverState.togglePinned() }
        showPopover()
        if isPopoverVisible { popover?.focus() }
    }

    func dismissPopover() {
        popoverState.dismiss()
        popover?.close()
    }

    func dismissPopoverIfOutside(at point: NSPoint) {
        guard isPopoverVisible, screenFrame?.contains(point) != true,
              popover?.screenFrame?.contains(point) != true else { return }
        dismissPopover()
    }

    private func showPopover() {
        guard let button = statusButton, button.window?.isVisible == true else {
            popoverState.dismiss(); return
        }
        if popover == nil {
            let popover = MenuBarPopoverController()
            popover.onClose = { [weak self] in self?.popoverState.dismiss() }
            self.popover = popover
        }
        if !isPopoverVisible { onPresentPopover() }
        popover?.show(makePopoverView(), relativeTo: button, appearance: settings.appearanceMode.nsAppearance)
        if !isPopoverVisible { popoverState.dismiss() }
    }

    private func makePopoverView() -> MenuBarPopoverView {
        let source = source(for: displayedMetric.platform)
        return MenuBarPopoverView(model: model, settings: settings, source: source,
            canRefresh: canRefreshDisplayed,
            onRefresh: { [weak self] in self?.refreshDisplayedPlatform() },
            onAnalysis: { [weak self, weak source] in
                guard let self, let source else { return }
                self.dismissPopover()
                UsageAnalysisWindowController.shared.show(model: self.model, account: source.account)
            }, onSettings: { [weak self] in
                self?.dismissPopover()
                self?.onShowSettings()
            }, onClose: { [weak self] in self?.dismissPopover() })
    }

    @objc private func openDetails() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)),
           let button = statusButton {
            dismissPopover()
            quickMenuActive = true
            defer { quickMenuActive = false }
            makeQuickMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else { togglePopover() }
    }
}
