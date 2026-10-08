import Foundation

enum ResetReminderDestination: String, Codable, CaseIterable, Identifiable {
    case notification, reminders
    var id: String { rawValue }
    var title: String { self == .notification ? "预约通知" : "系统提醒事项" }
}
enum ResetReminderLead: Int, Codable, CaseIterable, Identifiable {
    case atTime = 0, fifteenMinutesEarly = 900
    var id: Int { rawValue }
    var title: String { self == .atTime ? "到点提醒" : "提前 15 分钟" }
}
struct ResetReminderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct ResetReminderPlan: Codable, Equatable, Sendable {
    let event: OfficialResetAnnouncement
    let selectedDate: Date
    let lead: ResetReminderLead
    let destination: ResetReminderDestination
    var notifyAt: Date { selectedDate.addingTimeInterval(-Double(lead.rawValue)) }
    static func make(event: OfficialResetAnnouncement, selectedDate: Date?, lead: ResetReminderLead,
                     destination: ResetReminderDestination, now: Date = .now) throws -> Self {
        let options = event.reminderDates
        guard event.phase == .scheduled, !options.isEmpty, OfficialResetAnnouncement.validSource(event.sourceURL) else {
            throw ResetReminderError(message: "公告尚未提供明确的未来时间，暂时不能预约。")
        }
        guard let date = selectedDate ?? (options.count == 1 ? options[0] : nil), options.contains(date) else {
            throw ResetReminderError(message: "原帖时区有歧义，请先选择要提醒的北京时间。")
        }
        let plan = Self(event: event, selectedDate: date, lead: lead, destination: destination)
        guard plan.notifyAt > now.addingTimeInterval(5) else {
            throw ResetReminderError(message: "这个提醒时间已经过去或马上到达，请选择更晚的时刻或到点提醒。")
        }
        return plan
    }
    func remainingDescription(at now: Date = .now) -> String {
        let seconds = notifyAt.timeIntervalSince(now)
        guard seconds > 0 else { return "预约提醒时间已到" }
        let minutes = Int(ceil(seconds / 60)), days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        return "距提醒还有 " + (days > 0 ? "\(days)天 " : "") + (hours > 0 ? "\(hours)小时 " : "") + "\(rest)分钟"
    }
}
struct ResetReminderRecord: Codable, Equatable, Sendable {
    let plan: ResetReminderPlan
    let externalID: String?
}
extension OfficialResetAnnouncement {
    var reminderDates: [Date] { Array(Set([expectedAt, latestExpectedAt].compactMap { $0 })).sorted() }
    static func beijingDate(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")!; f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date) + "（北京时间）"
    }
    var notificationJSON: String? {
        guard let data = try? JSONEncoder().encode(self), data.count < 32768 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func fromNotificationJSON(_ value: String?) -> Self? {
        guard let value, value.utf8.count < 32768, let data = value.data(using: .utf8),
              let event = try? JSONDecoder().decode(Self.self, from: data), validSource(event.sourceURL),
              event.sourceURL.lastPathComponent == event.id else { return nil }
        return event
    }
}
