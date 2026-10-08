import SwiftUI

struct ResetCountdown {
    static func text(resetAt: Date?, usedPercent: Double?, fresh: Bool, at now: Date) -> String {
        guard let resetAt else { return "—" }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else {
            guard fresh else { return "等待更新确认" }
            return (usedPercent ?? 100) >= 80 ? "正在确认额度" : "重置时间已到"
        }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 { return "\(minutes)分钟后" }
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)天\(hours % 24)小时后" }
        return "\(hours)小时\(minutes % 60)分后"
    }
}

struct ResetTimeView: View {
    let row: DetailMetricRow
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .trailing, spacing: 1) {
                Text(ResetCountdown.text(resetAt: row.resetAt, usedPercent: row.resetUsedPercent,
                    fresh: row.resetFresh, at: context.date))
                    .font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Text(row.value).font(.system(size: 8)).opacity(0.5).lineLimit(1)
            }
            .help("预计重置时间：" + row.value + "；以平台实际返回的额度为准。")
        }
    }
}
