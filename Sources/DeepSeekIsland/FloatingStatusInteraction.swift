import Foundation

/// Collapse timing is independent of drawing, so crossing into the details card
/// or dragging cannot accidentally put the bar back into the edge.
struct FloatingStatusInteraction {
    private(set) var collapsed = false
    private var outsideSince: Date?
    mutating func reveal() { collapsed = false; outsideSince = nil }
    mutating func update(insideBar: Bool, insideCard: Bool, docked: Bool, dragging: Bool, at now: Date) {
        if !docked || dragging || insideBar || insideCard { reveal(); return }
        if outsideSince == nil { outsideSince = now }
        if let outsideSince, now.timeIntervalSince(outsideSince) >= 0.6 { collapsed = true }
    }
}
