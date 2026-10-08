import AppKit
import Combine
import SwiftUI

/// 与设置共享同一检查结果，不为详情另开网络轮询。
@MainActor
final class OfficialResetCardState: ObservableObject {
    @Published var announcement: OfficialResetAnnouncement?
    @Published var lastChecked: Date?
    @Published var error: String?
    var onReserve: ((OfficialResetAnnouncement) -> Void)?
    @Published var isPopoverPresented = false
}

struct OfficialResetCardContent: Equatable {
    let event: OfficialResetAnnouncement
    let title: String
    let time: String
    let detail: String
    let canReserve: Bool

    private static func beijingStamp(_ date: Date, sameDayAs first: Date? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = first.map { calendar.isDate(date, inSameDayAs: $0) } == true ? "HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
    static func make(_ event: OfficialResetAnnouncement?, enabled: Bool, now: Date = .now) -> Self? {
        guard enabled, let event, OfficialResetAnnouncement.validSource(event.sourceURL),
              event.announcedAt <= now.addingTimeInterval(300),
              (now.timeIntervalSince(event.announcedAt) <= 86400
               || (event.phase == .scheduled && event.latestExpectedAt.map { $0 > now } == true)) else { return nil }
        let banked = event.resetType == "banked"
        let upcoming = event.phase == .scheduled && event.latestExpectedAt.map { $0 > now } == true
        let passed = event.phase == .scheduled && event.latestExpectedAt.map { $0 <= now } == true
        let title = banked ? (event.phase == .scheduled ? "重置券发放预告" : "重置券发放动态")
            : (event.phase == .scheduled ? "官方重置预告" : "官方重置动态")
        let time: String
        if event.phase == .reported {
            time = "公告北京时间 " + beijingStamp(event.announcedAt)
        } else if let first = event.expectedAt {
            time = "预计北京时间 " + beijingStamp(first)
                + (event.latestExpectedAt.flatMap { $0 != first ? "–" + beijingStamp($0, sameDayAs: first) : nil } ?? "")
        } else { time = "尚未公布明确时间" }
        let detail = banked ? "重置券需手动使用，到账以账号为准。"
            : passed ? "预告时间已到，等待确认；请检查账号额度。"
            : "公开公告不代表当前账号额度已恢复。"
        return .init(event: event, title: title, time: time, detail: detail, canReserve: upcoming)
    }
}

struct OfficialResetDetailCard: View {
    let content: OfficialResetCardContent
    var lastChecked: Date?
    var error: String?
    var onReserve: (OfficialResetAnnouncement) -> Void = { _ in }
    var onPopoverChange: (Bool) -> Void = { _ in }
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    private var palette: IslandPalette { IslandPalette(scheme: scheme) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let current = OfficialResetCardContent.make(content.event, enabled: true, now: context.date) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(current.event.resetType == "banked" ? "重置券提醒" : (current.event.phase == .scheduled ? "官方重置提醒" : "官方重置动态"))
                            .font(.system(size: 9.5, weight: .medium))
                        Spacer(minLength: 0)
                        Text(current.time.replacingOccurrences(of: "预计北京时间 ", with: "").replacingOccurrences(of: "公告北京时间 ", with: ""))
                            .font(.system(size: 9.5)).monospacedDigit()
                    }
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .frame(height: 13)
                    .foregroundStyle(palette.accent.opacity(0.85))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onChange(of: expanded) { _, value in onPopoverChange(value) }
                .onDisappear { expanded = false; onPopoverChange(false) }
                .help(current.time + "。" + current.detail + " 点击查看原帖与预约入口。")
                .popover(isPresented: $expanded, arrowEdge: .top) {
                    card(current, now: context.date).padding(12).frame(width: 300)
                }
            }
        }
    }
    private func card(_ content: OfficialResetCardContent, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(content.title, systemImage: "text.bubble.fill")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.accent)
            Text(content.time).font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(content.detail).font(.system(size: 9)).foregroundStyle(palette.foreground.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            if error != nil || lastChecked.map({ now.timeIntervalSince($0) > 3600 }) == true {
                Text("保留上次公告，等待更新").font(.system(size: 9)).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("查看原帖 ↗") { NSWorkspace.shared.open(content.event.sourceURL) }
                Spacer(minLength: 0)
                if content.canReserve {
                    Button("到时提醒我") { onReserve(content.event) }
                }
            }
            .buttonStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(palette.accent)
        }
        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.accent.opacity(scheme == .dark ? 0.09 : 0.065), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.accent.opacity(0.23), lineWidth: 0.7))
        .help("来源：Codex Resets 整理的 Tibo 公告。" + content.event.timeDescription)
    }
}
