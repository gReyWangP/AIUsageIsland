import SwiftUI

/// 全部形态变化共用高阻尼弹簧；同一属性在动画中改目标时可连续接续。
enum IslandMotion {
    static let surface = Animation.spring(response: 0.38, dampingFraction: 1.0,
                                          blendDuration: 0.12)
    static let content = Animation.easeInOut(duration: 0.22)
}

struct IslandSurfaceTransition: Equatable {
    var revision: Int = 0
    var size: CGSize = .zero
    var mode: IslandPresentation.Mode = .hidden
    var animated = false
}

/// 动画期间保留窗口的可绘制区域；只有最新一次完成回调可收拢窗口。
struct IslandWindowTransition {
    private(set) var revision = 0
    private(set) var target: CGRect?

    mutating func begin(from current: CGRect, to target: CGRect, animated: Bool) -> CGRect {
        revision += 1
        self.target = target
        return animated ? current.union(target) : target
    }

    mutating func invalidate() { revision += 1; target = nil }

    mutating func complete(revision: Int) -> CGRect? {
        guard revision == self.revision, let target else { return nil }
        self.target = nil
        return target
    }
}

extension View {
    @ViewBuilder
    func islandMatchedPosition(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace, properties: .position)
        } else {
            self
        }
    }
}

/// 画布尺寸立即改变坐标系，内容尺寸作为一对数值补间。
/// 把定位放在补间器内计算，避免旧窗口的局部中心也参与动画。
struct IslandCenteredFrame: AnimatableModifier {
    var size: CGSize
    var canvasWidth: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set { size = CGSize(width: newValue.first, height: newValue.second) }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: max(0, size.width), height: max(0, size.height), alignment: .top)
            .position(x: canvasWidth / 2, y: max(0, size.height) / 2)
            // 当前帧已由 animatableData 提供，不能再给坐标套第二层补间。
            .transaction { $0.animation = nil }
    }
}

/// 直接使用与外框同一进度，保持卡片位置和宽高在一个补间中。
struct IslandCompactFlowLayout: Layout {
    var width: CGFloat
    var horizontalProgress: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let heights = subviews.map { $0.sizeThatFits(.unspecified).height }
        let progress = min(1, max(0, horizontalProgress))
        let vertical = heights.reduce(0, +)
        let horizontal = heights.max() ?? 0
        return CGSize(width: width, height: vertical + (horizontal - vertical) * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let heights = subviews.map { $0.sizeThatFits(.unspecified).height }
        let progress = min(1, max(0, horizontalProgress))
        let count = CGFloat(subviews.count)
        let cellWidth = bounds.width * (1 - progress + progress / count)
        let rowHeight = heights.max() ?? 0
        var verticalY: CGFloat = 0
        for index in subviews.indices {
            let horizontalX = ((CGFloat(index) + 0.5) / count - 0.5) * bounds.width
            let verticalCenter = verticalY + heights[index] / 2
            let y = verticalCenter + (rowHeight / 2 - verticalCenter) * progress
            subviews[index].place(at: CGPoint(x: bounds.midX + horizontalX * progress,
                                              y: bounds.minY + y),
                                 anchor: .center,
                                 proposal: ProposedViewSize(width: cellWidth, height: heights[index]))
            verticalY += heights[index]
        }
    }
}

/// 悬浮卡片和容器共享同一个动画向量，子布局直接使用当前帧的进度。
struct IslandCompactMorph: View, Animatable {
    let snapshots: [PlatformSnapshot]
    let layout: CompactLayout
    let hasNotch: Bool
    let horizontalWidth: CGFloat
    let notchWidth: CGFloat
    let bandHeight: CGFloat
    var size: CGSize
    var canvasWidth: CGFloat
    var horizontalProgress: CGFloat
    var onContentSizeChange: (CompactLayout, CGSize) -> Void
    var onTap: () -> Void

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(size.width, size.height), horizontalProgress) }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            horizontalProgress = newValue.second
        }
    }

    var body: some View {
        IslandCompactBar(snapshots: snapshots, layout: layout, hasNotch: hasNotch,
                         horizontalWidth: horizontalWidth, notchWidth: notchWidth,
                         bandHeight: bandHeight,
                         currentWidth: size.width, currentProgress: horizontalProgress,
                         onContentSizeChange: onContentSizeChange, onTap: onTap)
            .frame(width: max(0, size.width), height: max(0, size.height), alignment: .top)
            .position(x: canvasWidth / 2, y: max(0, size.height) / 2)
            .transaction { $0.animation = nil }
    }
}
