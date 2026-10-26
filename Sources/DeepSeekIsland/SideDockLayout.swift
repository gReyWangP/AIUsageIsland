import SwiftUI

enum IslandDisplayMode: String, CaseIterable {
    case island, floating, sideDock
}

enum SideDockLayout {
    static let width: CGFloat = 62
    static let itemHeight: CGFloat = 88
    static let contentInset: CGFloat = 50
    static let minCurveDepth: CGFloat = 8
    static let maxCurveDepth: CGFloat = width
    static let defaultCurveDepth: CGFloat = 34
    static func frame(in bounds: CGRect, count: Int, onLeft: Bool, verticalPosition: CGFloat = 0.5) -> CGRect {
        let size = CGSize(width: min(width, bounds.width), height: min(CGFloat(max(1, count)) * (itemHeight + 2) + contentInset * 2, bounds.height))
        let available = max(0, bounds.height - size.height)
        let y = bounds.minY + available * min(1, max(0, verticalPosition))
        return CGRect(x: onLeft ? bounds.minX : bounds.maxX - size.width,
                      y: y, width: size.width, height: size.height)
    }
}

/// Low values round only the inner corners while the top/bottom edges stay
/// straight. Larger values morph that corner into the S-shaped shoulder.
struct SideDockShape: Shape {
    var docked: Bool
    var onLeft: Bool
    var curveDepth: CGFloat

    func path(in rect: CGRect) -> Path {
        guard docked else { return Capsule().path(in: rect) }
        let w = rect.width, h = rect.height
        let maxDepth = max(0, min(w, h / 2))
        let minDepth = min(SideDockLayout.minCurveDepth, maxDepth)
        let value = min(maxDepth, max(minDepth, curveDepth))
        let normalized = maxDepth > minDepth ? (value - minDepth) / (maxDepth - minDepth) : 0
        let cornerPhase: CGFloat = 0.3
        func smoothstep(_ t: CGFloat) -> CGFloat {
            let x = min(1, max(0, t))
            return x * x * (3 - 2 * x)
        }
        let corner = min(maxDepth, 20) * smoothstep(normalized / cornerPhase)
        let blend = smoothstep((normalized - cornerPhase) / max(0.0001, 1 - cornerPhase))
        let depth = corner + (maxDepth - corner) * blend
        let k: CGFloat = 0.5522847498
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * blend, y: a.y + (b.y - a.y) * blend)
        }
        let aEnd = lerp(CGPoint(x: corner, y: 0), CGPoint(x: w / 2, y: depth / 2))
        let aC1 = lerp(CGPoint(x: w + (corner - w) / 3, y: 0), CGPoint(x: w, y: depth * k / 2))
        let aC2 = lerp(CGPoint(x: w + 2 * (corner - w) / 3, y: 0), CGPoint(x: w / 2 * (1 + k), y: depth / 2))
        let bC1 = lerp(CGPoint(x: corner * (1 - k), y: 0), CGPoint(x: w / 2 * (1 - k), y: depth / 2))
        let bC2 = lerp(CGPoint(x: 0, y: corner * (1 - k)), CGPoint(x: 0, y: depth - depth * k / 2))
        func mirror(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: h - point.y) }
        var path = Path()
        path.move(to: CGPoint(x: w, y: 0))
        path.addCurve(to: aEnd, control1: aC1, control2: aC2)
        path.addCurve(to: CGPoint(x: 0, y: depth), control1: bC1, control2: bC2)
        path.addLine(to: CGPoint(x: 0, y: h - depth))
        path.addCurve(to: mirror(aEnd), control1: mirror(bC2), control2: mirror(bC1))
        path.addCurve(to: CGPoint(x: w, y: h), control1: mirror(aC2), control2: mirror(aC1))
        path.closeSubpath()
        let transform = onLeft
            ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.maxX, ty: rect.minY)
            : CGAffineTransform(translationX: rect.minX, y: rect.minY)
        return path.applying(transform)
    }
}

extension UsageReading {
    var sideDockText: String {
        switch self {
        case .quota(let remaining, _): remaining.isFinite ? String(format: "%.0f%%", max(0, min(100, remaining))) : "—"
        case .balance: balanceText ?? "—"
        case .unlimited: "∞"
        case .unavailable: "—"
        }
    }
}
