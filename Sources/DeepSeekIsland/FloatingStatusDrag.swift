import AppKit

/// A live drag owns transient orientation and interpolated size. Persistent
/// placement changes only on release; reversing a morph starts at its current size.
struct FloatingStatusDrag {
    private(set) var edge: FloatingStatusEdge
    private var pointer: CGPoint
    private let anchor: CGPoint
    private let activationDistance: CGFloat
    private var from: CGSize
    private var target: CGSize
    private var started: Date?
    var duration: TimeInterval = 0.24

    init(frame: CGRect, pointer: CGPoint, edge: FloatingStatusEdge) {
        self.edge = edge
        self.pointer = pointer
        anchor = CGPoint(x: min(1, max(0, (pointer.x - frame.minX) / max(1, frame.width))),
                         y: min(1, max(0, (pointer.y - frame.minY) / max(1, frame.height))))
        // Include the capsule's reach around its grab point. A horizontal bar
        // can touch the side before its pointer does; keep that intent stable
        // when the bar narrows, rather than switching back on the next event.
        activationDistance = min(120, max(56, max(frame.width, frame.height) / 2 + 24))
        from = frame.size; target = frame.size
    }
    mutating func update(pointer: CGPoint, in bounds: CGRect, count: Int, at now: Date) {
        self.pointer = pointer
        let top = abs(bounds.maxY - pointer.y)
        let left = abs(pointer.x - bounds.minX), right = abs(bounds.maxX - pointer.x)
        if top <= activationDistance && top <= min(left, right) { edge = .top }
        else if edge == .top && top <= activationDistance + 28 && top <= min(left, right) + 20 { edge = .top }
        else if left <= activationDistance { edge = .left }
        else if right <= activationDistance { edge = .right }
        else if edge == .left && left <= activationDistance + 28 { edge = .left }
        else if edge == .right && right <= activationDistance + 28 { edge = .right }
        else { edge = .free }
        let wanted = FloatingStatusLayout.size(edge: edge, count: count, bounds: bounds)
        if wanted != target {
            from = frame(at: now).size
            target = wanted
            started = now
        }
    }
    func frame(at now: Date) -> CGRect {
        let t = started.map { duration > 0 ? min(1, max(0, now.timeIntervalSince($0) / duration)) : 1 } ?? 1
        let progress = t * t * (3 - 2 * t)
        let size = CGSize(width: from.width + (target.width - from.width) * progress,
                          height: from.height + (target.height - from.height) * progress)
        return CGRect(x: pointer.x - size.width * anchor.x, y: pointer.y - size.height * anchor.y,
                      width: size.width, height: size.height)
    }
    var targetSize: CGSize { target }
    func targetFrame() -> CGRect {
        CGRect(x: pointer.x - target.width * anchor.x, y: pointer.y - target.height * anchor.y,
               width: target.width, height: target.height)
    }
}
