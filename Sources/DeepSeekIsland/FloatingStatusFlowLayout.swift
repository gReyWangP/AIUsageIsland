import SwiftUI

/// Keep the same icon views alive while interpolating their positions between
/// a column and a row. Switching stack types would jump directly to the end.
struct FloatingStatusFlowLayout: Layout {
    var itemHeight: CGFloat = 48
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    static func center(index: Int, progress: CGFloat) -> CGPoint {
        let p = min(1, max(0, progress))
        return CGPoint(x: 24 + CGFloat(index) * 50 * p,
                       y: 24 + CGFloat(index) * 50 * (1 - p))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let p = min(1, max(0, progress))
        let extra = CGFloat(max(0, subviews.count - 1)) * (itemHeight + 2)
        return CGSize(width: 48 + extra * p, height: itemHeight + extra * (1 - p))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for index in subviews.indices {
            let point = CGPoint(x: 24 + CGFloat(index) * (itemHeight + 2) * progress,
                                y: itemHeight / 2 + CGFloat(index) * (itemHeight + 2) * (1 - progress))
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  anchor: .center, proposal: ProposedViewSize(width: 48, height: itemHeight))
        }
    }
}
