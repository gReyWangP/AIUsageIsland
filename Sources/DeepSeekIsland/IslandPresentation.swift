import Combine
import CoreGraphics
import Foundation

@MainActor
final class IslandPresentation: ObservableObject {
    enum Mode: Equatable {
        case hidden
        case compact
        case expanded
    }

    @Published var mode: Mode = .hidden {
        didSet {
            if expanded != (oldValue == .expanded) { onExpansionChanged?(expanded) }
            if oldValue == .expanded && mode != .expanded { transientRevealUntil = nil }
            if oldValue != mode { onModeChanged?() }
        }
    }
    var visible: Bool {
        get { mode != .hidden }
        set {
            if newValue && mode == .hidden { mode = .compact }
            if !newValue && mode != .hidden { mode = .hidden }
        }
    }
    var expanded: Bool {
        get { mode == .expanded }
        set {
            if newValue && mode != .expanded { mode = .expanded }
            if !newValue && mode == .expanded { mode = .compact }
        }
    }
    @Published var pinned = false {
        didSet { if pinned { transientRevealUntil = nil } }
    }

    // MARK: - 屏幕几何（由 AppDelegate 在切换屏幕时写入）

    @Published var hasNotch = false
    @Published var notchWidth: CGFloat = 185
    @Published var wingWidth: CGFloat = 190
    @Published var bandHeight: CGFloat = 32
    /// 详情顶部内边距。刘海屏要让开摄像头，外接屏不需要。
    @Published var topInset: CGFloat = 14
    /// 横向悬浮条的总宽度。
    @Published var horizontalBarWidth: CGFloat = NotchLayout.externalBarWidth
    /// 当前屏幕尺寸。宽度用于给详情面板封顶，高度用于限制详情最高不超过半屏。
    @Published var screenWidth: CGFloat = 1512
    @Published var screenHeight: CGFloat = 982

    // MARK: - 实测尺寸（由 IslandView 上报）

    /// 悬浮条实际尺寸。排版换了、平台数变了都会变，只能实测。
    @Published var compactSize = CGSize(width: NotchLayout.externalBarWidth, height: 55)
    /// 详情内容实际尺寸。
    @Published var detailSize = CGSize(width: 565, height: 320)

    // MARK: - 实测高度缓存

    /// 各排版实测的高度。**按排版分开存**：切换排版时若沿用上一个排版的高度，
    /// 就会发出「新宽度 + 旧高度」的混合尺寸。
    ///
    /// 放在这里而不是 View 的 `@State`：AppDelegate 在排版切换时要**立刻**
    /// 按新排版重算尺寸（SwiftUI 的 onChange / onPreferenceChange 实测不可靠），
    /// 而它拿不到 View 的 @State。故意不加 `@Published`——写它不该触发重绘。
    var compactHeights: [String: CGFloat] = [:]
    var detailHeights: [String: CGFloat] = [:]

    /// 悬浮条在某排版下的尺寸（宽度按策略，高度取该排版的缓存值）。
    func compactSize(for layout: CompactLayout) -> CGSize {
        let width = layout.barWidth(hasNotch: hasNotch,
                                    notchWidth: notchWidth,
                                    horizontalBarWidth: horizontalBarWidth)
        return CGSize(width: width, height: compactHeights[layout.rawValue] ?? compactSize.height)
    }

    /// 详情外框的固定开销：标题 20 + 两个 10 pt 间距 + 电源按钮 26 + 底部内边距 13。
    static let detailFrameOverhead: CGFloat = 79

    /// 详情在某排版下的尺寸。
    ///
    /// 缓存里存的是**内容**高度，必须加上顶部内边距与外框开销才是面板高度——
    /// 早期这里直接拿内容高度当面板高度，面板会比内容矮掉 93 pt。
    func detailSize(for layout: DetailLayout, platformCount: Int) -> CGSize {
        let width = layout.panelWidth(platformCount: platformCount, screenWidth: screenWidth)
        let content = detailHeights[layout.rawValue] ?? DetailLayout.defaultContentHeight
        let natural = content + topInset + Self.detailFrameOverhead
        let cap = screenHeight * 0.5
        let height = cap.isFinite && cap > 1 ? min(natural, cap) : 55
        return CGSize(width: width, height: height)
    }

    // MARK: - 设置

    /// 设置窗口是否打开。由 AppDelegate 在窗口开关时同步，用来切换齿轮图标。
    @Published var showingSettings = false
    /// 点击齿轮。设置页是**独立窗口**，不再塞进详情面板——
    /// 详情宽度按平台数计算（1 个平台只有 360 pt），
    /// 设置页挤在里面会又窄又高，还得滚动才能填完。
    var onToggleSettings: (() -> Void)?

    var onExpansionChanged: ((Bool) -> Void)?
    var onModeChanged: (() -> Void)?
    /// AppKit 提供目标，SwiftUI 回报真实动画完成，避免定时器提前裁切。
    @Published var surfaceTransition = IslandSurfaceTransition()
    var onSurfaceSettled: ((Int) -> Void)?
    private var transientRevealUntil: Date?

    func openDetails(at now: Date = .now) {
        mode = .expanded
        transientRevealUntil = pinned ? nil : now.addingTimeInterval(6)
    }

    func shouldWaitBeforeHiding(at now: Date, pointerInside: Bool) -> Bool {
        if pointerInside || pinned {
            transientRevealUntil = nil
            return false
        }
        return transientRevealUntil.map { now < $0 } ?? false
    }
}
