import AppKit

enum FloatingStatusEdge: String, Codable { case free, left, right, top }
struct FloatingStatusPlacement: Codable, Equatable {
    var edge: FloatingStatusEdge = .left
    var x: Double = 0
    var y: Double = 0.5
    var displayID: UInt32? = nil
    var displayName: String? = nil
}

/// Geometry is independent of windows, including recovery after a display disconnects.
enum FloatingStatusLayout {
    static let edgeInset: CGFloat = 3
    static func size(edge: FloatingStatusEdge, count: Int, bounds: CGRect) -> CGSize {
        let length = CGFloat(max(1, count)) * 50 + 14
        return edge == .top
            ? CGSize(width: min(length, max(1, bounds.width - 2 * edgeInset)), height: 62)
            : CGSize(width: 62, height: min(length, max(1, bounds.height - 2 * edgeInset)))
    }
    static func frame(edge: FloatingStatusEdge, position: CGPoint, in bounds: CGRect, count: Int) -> CGRect {
        let size = size(edge: edge, count: count, bounds: bounds)
        let availableX = max(0, bounds.width - size.width - 2 * edgeInset)
        let availableY = max(0, bounds.height - size.height - 2 * edgeInset)
        let x = position.x.isFinite ? min(1, max(0, position.x)) : 0
        let y = position.y.isFinite ? min(1, max(0, position.y)) : 0.5
        return CGRect(x: bounds.minX + edgeInset + (edge == .left ? 0 : edge == .right ? availableX : availableX * x),
                      y: bounds.minY + edgeInset + (edge == .top ? availableY : availableY * y),
                      width: size.width, height: size.height)
    }
    static func settle(frame proposed: CGRect, in bounds: CGRect, count: Int) -> (edge: FloatingStatusEdge, frame: CGRect) {
        let distances: [(FloatingStatusEdge, CGFloat)] = [(.left, abs(proposed.minX - bounds.minX)),
            (.right, abs(proposed.maxX - bounds.maxX)), (.top, abs(proposed.maxY - bounds.maxY))]
        let nearest = distances.min { $0.1 < $1.1 }!
        let edge: FloatingStatusEdge = nearest.1 <= 24 ? nearest.0 : .free
        let size = size(edge: edge, count: count, bounds: bounds)
        let origin = CGPoint(x: proposed.midX - size.width / 2, y: proposed.midY - size.height / 2)
        let position = normalized(origin: origin, size: size, in: bounds)
        return (edge, frame(edge: edge, position: position, in: bounds, count: count))
    }
    /// Keep the entire tucked strip on its own display, including adjacent displays.
    static func collapsedFrame(expanded: CGRect, edge: FloatingStatusEdge, screen: CGRect) -> CGRect {
        switch edge {
        case .left, .right:
            let height = min(64, screen.height)
            return CGRect(x: edge == .left ? screen.minX : screen.maxX - 8,
                          y: max(screen.minY, min(expanded.midY - height / 2, screen.maxY - height)),
                          width: 8, height: height)
        case .top:
            let width = min(64, screen.width)
            return CGRect(x: max(screen.minX, min(expanded.midX - width / 2, screen.maxX - width)),
                          y: screen.maxY - 8, width: width, height: 8)
        case .free: return expanded
        }
    }
    static func normalized(origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (origin.x - bounds.minX - edgeInset) / max(1, bounds.width - size.width - 2 * edgeInset))),
                y: min(1, max(0, (origin.y - bounds.minY - edgeInset) / max(1, bounds.height - size.height - 2 * edgeInset))))
    }
}
