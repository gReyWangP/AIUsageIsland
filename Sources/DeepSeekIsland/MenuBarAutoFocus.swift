import AppKit

struct MenuBarFocusCandidate {
    let metric: UsageMetric
    let data: UsageReading
    var rank: Int? {
        switch data {
        case .quota(let remaining, _):
            guard remaining.isFinite, (0...100).contains(remaining) else { return nil }
            return remaining <= 0 ? 3 : remaining < 10 ? 2 : remaining < 20 ? 1 : 0
        case .balance(let amount, let currency):
            guard !amount.isNaN, currency == "CNY" else { return nil }
            return amount <= 0 ? 3 : amount < 1 ? 2 : amount < 5 ? 1 : 0
        case .unavailable, .unlimited: return nil
        }
    }
    /// 同级按该级阈值归一化比较，不把人民币和百分比直接比较。
    var pressure: Double {
        switch data {
        case .quota(let remaining, _): return remaining / (rank == 2 ? 10 : 20)
        case .balance(let amount, _): return NSDecimalNumber(decimal: amount).doubleValue / (rank == 2 ? 1 : 5)
        case .unavailable, .unlimited: return 1
        }
    }
}

struct MenuBarAutoFocus {
    private var current: UsageMetric?
    private var changedAt = Date.distantPast
    private var lastRank = 0
    mutating func resolve(_ candidates: [MenuBarFocusCandidate], fallback: UsageMetric, at now: Date = .now, temporarilyLoading: UsageMetric? = nil) -> UsageMetric {
        let valid = candidates.filter { $0.rank != nil }
        if let temporarilyLoading, temporarilyLoading == current,
           (valid.compactMap(\.rank).max() ?? -1) <= lastRank { return temporarilyLoading }
        guard let highest = valid.compactMap(\.rank).max() else {
            current = nil; return fallback
        }
        let active = current.flatMap { metric in valid.first { $0.metric == metric } }
        let urgent = valid.filter { $0.rank == highest }
        let best: MenuBarFocusCandidate
        if highest == 0 {
            best = active ?? urgent.first { $0.metric == fallback } ?? urgent[0]
        } else {
            let minimum = urgent.map(\.pressure).min()!
            let ties = urgent.filter { abs($0.pressure - minimum) < 0.000001 }
            best = ties.first { $0.metric == current } ?? ties.first { $0.metric == fallback } ?? ties[0]
        }
        if let active, best.metric != active.metric {
            let worse = highest > active.rank!
            let meaningful = highest != active.rank || active.pressure - best.pressure >= 0.15
            if !worse && (now.timeIntervalSince(changedAt) < 60 || !meaningful) {
                lastRank = active.rank ?? 0
                return active.metric
            }
        }
        if current != best.metric { current = best.metric; changedAt = now }
        lastRank = best.rank ?? 0
        return best.metric
    }
}

extension MenuBarRenderer {
    static func autoImage(platform: UsagePlatform, data: UsageReading, dark: Bool,
                          thickness: MenuBarRingThickness = .standard, style: MenuBarProgressStyle = .ring,
                          windowLabel: String? = nil) -> NSImage {
        let base = image(platform: platform, data: data, dark: dark, thickness: thickness, style: style)
        guard platform != .deepSeek else { return base }
        let window: String
        if let windowLabel { window = windowLabel }
        else if case .quota(_, let label) = data { window = label }
        else { return base }
        let tag = window == "本周" ? "周" : window == "5 小时" ? "5h" : window
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: dark ? NSColor.white : NSColor.black]
        let text = NSAttributedString(string: tag, attributes: attributes)
        let width = ceil(text.size().width)
        let result = NSImage(size: NSSize(width: base.size.width + 3 + width, height: 18), flipped: false) { _ in
            base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            text.draw(at: NSPoint(x: base.size.width + 3, y: (18 - text.size().height) / 2))
            return true
        }
        result.isTemplate = false
        return result
    }
}
