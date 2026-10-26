import SwiftUI
import AppKit

@MainActor final class SideDockCalloutSurface: ObservableObject {
    @Published var pointerY: CGFloat = 100
}

/// The point is part of the same silhouette as the card, with curved roots.
struct SideDockCalloutShape: Shape {
    var pointsLeft: Bool
    var pointerY: CGFloat
    static let pointerWidth: CGFloat = 24
    static let pointerHalfHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let tip = min(Self.pointerWidth, max(8, w / 4))
        let r = min(Self.cornerRadius, h / 4)
        let end = w - tip
        let margin = min(h / 2, r + Self.pointerHalfHeight)
        let y = min(h - margin, max(margin, pointerY))
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (pointsLeft ? w - x : x), y: rect.minY + y)
        }
        var p = Path()
        p.move(to: point(r, 0))
        p.addLine(to: point(end - r, 0))
        p.addQuadCurve(to: point(end, r), control: point(end, 0))
        p.addLine(to: point(end, y - Self.pointerHalfHeight))
        p.addCurve(to: point(w, y),
                   control1: point(end, y - 10),
                   control2: point(w - 10, y - 5))
        p.addCurve(to: point(end, y + Self.pointerHalfHeight),
                   control1: point(w - 10, y + 5),
                   control2: point(end, y + 10))
        p.addLine(to: point(end, h - r))
        p.addQuadCurve(to: point(end - r, h), control: point(end, h))
        p.addLine(to: point(r, h))
        p.addQuadCurve(to: point(0, h - r), control: point(0, h))
        p.addLine(to: point(0, r))
        p.addQuadCurve(to: point(r, 0), control: point(0, 0))
        p.closeSubpath()
        return p
    }
}

/// Capture the actual icon location, including scrolling, rather than estimating row positions.
struct FloatingIconAnchor: NSViewRepresentable {
    let onResolve: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onResolve(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { onResolve(view) }
}

enum SideDockCalloutLayout {
    static let margin = SideDockCalloutShape.cornerRadius + SideDockCalloutShape.pointerHalfHeight
    static func pointerY(icon: CGRect, card: CGRect) -> CGFloat {
        let limit = min(card.height / 2, margin)
        return min(card.height - limit, max(limit, card.maxY - icon.midY))
    }
}
